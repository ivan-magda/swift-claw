import ClawCore
import Foundation
import Logging

/// The fail-closed callback auth chain. Every failure is audited (`messageIn`/`forbidden`) and
/// answered with a neutral toast, and the approval row is left untouched. A valid owner tap CASes the
/// durable row and signals the coordinator — the waiter performs the resume/deny. The
/// handler itself only claims, authorizes, CASes, signals, and toasts; it never touches the
/// observation row, the run state, or the button keyboard.
public struct ApprovalCallbackHandler: Sendable {
  private let replies: ReplySender
  private let accessControl: AccessControl

  private let approvals: any ApprovalStore
  private let audit: any AuditLog

  private let coordinator: ApprovalCoordinator
  private let callbacks: any CallbackResponding

  private let currentPolicyVersion: @Sendable () throws -> String
  private let now: @Sendable () -> Date

  private let logger: Logger

  // Module-internal init: `ReplySender`/`RoutingHalt` are internal to `ClawGateway`, so a `public`
  // init would not compile ("parameter uses an internal type"). The daemon composes the handler
  // through the public `make(...)` factory below — `makeDaemon` injects the result into the
  // production `MessageRouter` via `approvalCallbacks`; tests reach the init directly through
  // `@testable import ClawGateway`. The `handle(_:updateId:)` surface stays public.
  init(
    replies: ReplySender,
    accessControl: AccessControl,
    approvals: any ApprovalStore,
    audit: any AuditLog,
    coordinator: ApprovalCoordinator,
    callbacks: any CallbackResponding,
    currentPolicyVersion: @escaping @Sendable () throws -> String,
    now: @escaping @Sendable () -> Date,
    logger: Logger
  ) {
    self.replies = replies
    self.accessControl = accessControl

    self.approvals = approvals
    self.audit = audit

    self.coordinator = coordinator
    self.callbacks = callbacks

    self.currentPolicyVersion = currentPolicyVersion
    self.now = now

    self.logger = logger
  }

  /// Composition factory for the `clawd` module. `ReplySender` and the init are `ClawGateway`-internal,
  /// so the daemon cannot call the init directly; this builds the internal `ReplySender` from public
  /// ingredients and returns the composed handler. `makeDaemon` calls it and injects the
  /// result into the production `MessageRouter` via `approvalCallbacks`.
  public static func make(  // swiftlint:disable:this function_parameter_count
    processed: any ProcessedUpdateStore,
    delivery: any MessageDelivery,
    accessControl: AccessControl,
    approvals: any ApprovalStore,
    audit: any AuditLog,
    coordinator: ApprovalCoordinator,
    callbacks: any CallbackResponding,
    currentPolicyVersion: @escaping @Sendable () throws -> String,
    now: @escaping @Sendable () -> Date,
    logger: Logger
  ) -> ApprovalCallbackHandler {
    ApprovalCallbackHandler(
      replies: ReplySender(processed: processed, delivery: delivery, logger: logger),
      accessControl: accessControl,
      approvals: approvals,
      audit: audit,
      coordinator: coordinator,
      callbacks: callbacks,
      currentPolicyVersion: currentPolicyVersion,
      now: now,
      logger: logger
    )
  }

  /// Step 1 (claim), then the auth chain. Returns a `HandleOutcome` so the poller's
  /// cursor-advance semantics are identical to the message path: a redelivered update is deduped by
  /// the shared `processed_updates` claim and skipped.
  public func handle(_ callback: RawCallback, updateId: Int64) async -> HandleOutcome {
    let noticeChatId = callback.chatId ?? callback.fromUserId

    do throws(RoutingHalt) {
      try await replies.claimUpdate(updateId: updateId, chatId: noticeChatId)
    } catch {
      return error.outcome
    }

    return await resolve(callback)
  }
}

// MARK: - Auth chain

private extension ApprovalCallbackHandler {
  func resolve(_ callback: RawCallback) async -> HandleOutcome {
    // Step 2: allowlist default-deny, before any parsing.
    guard accessControl.isAllowed(userId: callback.fromUserId) else {
      return await denyAuth(callback, approval: nil)
    }
    // Step 3: parse callback_data strictly (apr:<nonce>:<verdict>).
    guard let parsed = callback.data.flatMap(ApprovalKeyboard.parse) else {
      return await denyAuth(callback, approval: nil)
    }
    // Step 4: look up by nonce ONLY (unique index) — never by a guessable id.
    let found: Approval?
    do {
      found = try approvals.approval(nonce: parsed.nonce)
    } catch {
      return await storeFailure(callback, error)
    }
    guard let approval = found else {
      return await denyAuth(callback, approval: nil)
    }
    // Step 5: owner binding.
    guard callback.fromUserId == approval.ownerUserId else {
      return await denyAuth(callback, approval: approval)
    }

    return await commitResolution(callback, approval: approval, verdict: parsed.verdict)
  }
}

// MARK: - Resolution CAS

private extension ApprovalCallbackHandler {
  func commitResolution(
    _ callback: RawCallback,
    approval: Approval,
    verdict: ApprovalKeyboard.Verdict
  ) async -> HandleOutcome {
    switch verdict {
    case .approve:
      return await commitApprove(callback, approval: approval, openTurnWindow: false)
    case .approveForTurn:
      // The reason is what the prompt drew its buttons from, so an approval that never offered
      // the widening resolves as the plain approval it did offer — no window opens off a verdict
      // the owner had no button for.
      return await commitApprove(
        callback,
        approval: approval,
        openTurnWindow: approval.reason.offersTurnScopedWindow
      )
    case .deny:
      return await commitDeny(callback, approval: approval)
    }
  }

  func commitApprove(
    _ callback: RawCallback,
    approval: Approval,
    openTurnWindow: Bool
  ) async -> HandleOutcome {
    let policyVersion: String
    do {
      policyVersion = try currentPolicyVersion()
    } catch {
      return await storeFailure(callback, error)
    }

    let outcome: ApprovalApproveOutcome
    do {
      outcome = try approvals.approve(
        id: approval.id,
        currentPolicyVersion: policyVersion,
        openTurnWindow: openTurnWindow,
        now: now()
      )
    } catch {
      return await storeFailure(callback, error)
    }

    switch outcome {
    case .approved:
      await coordinator.signal(approvalId: approval.id, .approved)
      return await finish(
        callback,
        toast: openTurnWindow ? Self.approvedForTurnToast : Self.approvedToast
      )
    case .stalePolicy:
      await coordinator.signal(approvalId: approval.id, .denied(.stalePolicy))
      return await finish(callback, toast: Self.stalePolicyToast)
    case .notPending:
      return await finish(callback, toast: Self.alreadyHandledToast)
    case .expiredRow:
      return await commitExpiry(callback, approval: approval)
    }
  }

  /// The approve CAS found the row already past its deadline: route it through the deny path so the
  /// waiter fails the run exactly as the ticker would.
  func commitExpiry(_ callback: RawCallback, approval: Approval) async -> HandleOutcome {
    let denied: Bool
    do {
      denied = try approvals.deny(id: approval.id, decision: .expired, now: now())
    } catch {
      return await storeFailure(callback, error)
    }

    if denied {
      await coordinator.signal(approvalId: approval.id, .denied(.expired))
    }

    return await finish(callback, toast: Self.expiredToast)
  }

  func commitDeny(_ callback: RawCallback, approval: Approval) async -> HandleOutcome {
    let denied: Bool
    do {
      denied = try approvals.deny(id: approval.id, decision: .rejected, now: now())
    } catch {
      return await storeFailure(callback, error)
    }

    guard denied else {
      // A racing resolver (ticker/duplicate) already won; nothing to signal, answer neutrally.
      return await finish(callback, toast: Self.alreadyHandledToast)
    }
    await coordinator.signal(approvalId: approval.id, .denied(.rejected))

    return await finish(callback, toast: Self.deniedToast)
  }
}

// MARK: - Fail-closed helpers

private extension ApprovalCallbackHandler {
  /// An auth failure is an access event, not an approval decision: audit `messageIn`/
  /// `forbidden` (actor `owner` only when the sender IS the owner, else `system`), answer a neutral
  /// toast, leave the row untouched.
  func denyAuth(_ callback: RawCallback, approval: Approval?) async -> HandleOutcome {
    let auditActor: AuditActor = approval?.ownerUserId == callback.fromUserId ? .owner : .system
    let event = AuditEvent(
      actor: auditActor,
      action: .messageIn,
      decision: Self.forbiddenDecision,
      runId: approval?.runId,
      sessionId: approval?.sessionId,
      ts: now()
    )

    do {
      try audit.appendAudit(event)
    } catch {
      logger.error("failed to audit forbidden callback: \(error)")
    }

    return await finish(callback, toast: Self.neutralToast)
  }

  /// A transient store failure after the claim: the update is already consumed, so a re-poll would
  /// only hit the duplicate claim. Fail closed — no CAS means no execution — and leave the PENDING
  /// row for the expiry ticker or a fresh owner tap. Because the row is still tappable, the toast
  /// says "try again" (not the neutral "no longer available" copy). The spinner is still stopped.
  func storeFailure(_ callback: RawCallback, _ error: any Error) async -> HandleOutcome {
    logger.error("callback resolution store failure: \(error)")
    return await finish(callback, toast: Self.retryToast)
  }

  /// Answer the callback (stop the client spinner) and report the update durably handled. The answer
  /// is best-effort: a lost toast must not re-run the resolution.
  func finish(_ callback: RawCallback, toast: String) async -> HandleOutcome {
    do {
      try await callbacks.answerCallbackQuery(id: callback.callbackId, text: toast)
    } catch {
      logger.warning("failed to answer callback \(callback.callbackId): \(error)")
    }
    return .processed
  }
}

// MARK: - Toasts

private extension ApprovalCallbackHandler {
  static let forbiddenDecision = "forbidden"
  static let neutralToast = "This action is no longer available."
  static let retryToast = "Something went wrong — please try again."
  static let approvedToast = "Approved."
  static let approvedForTurnToast = "Approved for this turn."
  static let deniedToast = "Denied."
  static let alreadyHandledToast = "Already handled."
  static let stalePolicyToast = "This approval is no longer valid."
  static let expiredToast = "This approval has expired."
}
