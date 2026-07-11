import ClawCore
import Foundation
import Logging

/// Executes an APPROVED action from its recorded canonical args and commits the observation/run
/// transition. No gate re-trip, no model turn — grant semantics are gone; this is
/// recorded-args execution. Tools are held by name as ClawCore `Tool`s: the executor never imports
/// `ClawTools`; the composition root injects the same instances the dispatcher uses.
public protocol ApprovedActionExecuting: Sendable {
  func executeApproved(_ approval: Approval) async -> ApprovedExecutionOutcome
}

/// How the executor's durable commit landed. Distinct from the store seam's vocabulary because a
/// THROWN store error is not a duplicate signal, and "did the action run?" changes what the
/// waiter may truthfully tell the owner.
public enum ApprovedCommitOutcome: Sendable, Equatable {
  /// This call performed the resume commit.
  case committed
  /// A duplicate signal already resumed the run; nothing left to do.
  case ignored
  /// The pre-execution claim threw at the store seam — nothing ran. The run is still
  /// `AWAITING_APPROVAL`, so the boot crash-window path (APPROVED row + AWAITING run)
  /// retries it after a restart.
  case storeFailed
  /// The action EXECUTED, then recording its result threw. The run stays claimed RUNNING for the
  /// boot orphan sweep — the waiter must never promise a retry: the side effect already happened.
  case recordFailed
  /// The run reached a terminal state (`/stop`, `/new`) after the approve CAS but before the
  /// claim: nothing executed, and the claim transaction resolved the placeholder observation.
  case runNotResumable
}

public struct ApprovedExecutionOutcome: Sendable, Equatable {
  /// What the placeholder observation now says (the waiter forwards nothing — the executor already
  /// committed it; this is returned for logging/assertions).
  public let observationContent: String
  /// `.committed` when this call performed the resume; `.ignored` when a duplicate already did.
  public let commit: ApprovedCommitOutcome

  public init(observationContent: String, commit: ApprovedCommitOutcome) {
    self.observationContent = observationContent
    self.commit = commit
  }
}

public struct ApprovedActionExecutor: ApprovedActionExecuting {
  /// `memory_write`'s side effect is a DB insert that must FUSE with the observation update for
  /// exactly-once, so it never runs the tool's `execute`; every other write tool claims the
  /// run first, executes its recorded args, then records the result.
  private static let memoryWriteToolName = "memory_write"

  /// Synthetic observation for an approval whose run `/stop`//`new` drove terminal before the
  /// claim — written by the claim transaction so history explains the un-run call.
  static let notResumableObservationContent =
    "The run was stopped before this approved action executed; nothing ran."

  /// Placeholder audit rendering while the exact-value redactor is not yet injected: the executor
  /// never writes the approval's raw canonical arguments into the audit log.
  private static let opaqueApprovedArguments = "[REDACTED:approved-arguments]"

  private let tools: [String: any Tool]
  private let runs: any RunStore
  private let now: @Sendable () -> Date
  private let logger: Logger

  public init(
    tools: [String: any Tool],
    runs: any RunStore,
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger
  ) {
    self.tools = tools
    self.runs = runs
    self.now = now
    self.logger = logger
  }

  public func executeApproved(_ approval: Approval) async -> ApprovedExecutionOutcome {
    if approval.tool == Self.memoryWriteToolName {
      return applyMemoryWrite(approval)
    }
    return await executeGenericWrite(approval)
  }
}

// MARK: - Generic Write Execution

private extension ApprovedActionExecutor {
  func executeGenericWrite(_ approval: Approval) async -> ApprovedExecutionOutcome {
    // Claim BEFORE the external effect: the AWAITING→RUNNING flip and a `/stop`//`new`
    // cancellation contend on the same run row, so exactly one side wins — an approved write can
    // never land after the owner cancelled the run.
    let claim: ApprovedExecutionClaim
    do {
      claim = try runs.claimApprovedExecution(
        runId: approval.runId,
        observationMessageId: approval.observationMessageId,
        notResumableObservationContent: Self.notResumableObservationContent,
        now: now()
      )
    } catch {
      logger.error("approved-execution claim failed for run \(approval.runId): \(error)")
      return ApprovedExecutionOutcome(observationContent: "", commit: .storeFailed)
    }
    switch claim {
    case .alreadyResumed:
      return ApprovedExecutionOutcome(observationContent: "", commit: .ignored)
    case .runNotResumable:
      return ApprovedExecutionOutcome(
        observationContent: Self.notResumableObservationContent,
        commit: .runNotResumable
      )
    case .committed:
      break
    }

    let content = await executedContent(for: approval)

    do {
      try runs.fillClaimedObservation(
        runId: approval.runId,
        observationMessageId: approval.observationMessageId,
        fill: ClaimedObservationFill(
          content: content,
          status: .ok,
          setTainted: false,
          setPrivateData: false,
          audit: ApprovedExecutionAudit(
            tool: approval.tool,
            argsRedacted: Self.opaqueApprovedArguments
          ),
          now: now()
        )
      )
    } catch {
      logger.error("recording the executed result failed for run \(approval.runId): \(error)")
      return ApprovedExecutionOutcome(observationContent: content, commit: .recordFailed)
    }
    return ApprovedExecutionOutcome(observationContent: content, commit: .committed)
  }

  /// Runs the claimed action and returns the observation content — a truthful error line when the
  /// recorded tool vanished or its args no longer parse.
  func executedContent(for approval: Approval) async -> String {
    guard
      let tool = tools[approval.tool],
      let arguments = JSONValue.parse(approval.canonicalArgsJSON)
    else {
      logger.error("approved action \(approval.tool) has no registered tool or unparsable args")
      return "That action could not run because its tool is no longer available."
    }
    // Run to completion on the waiter task — direct await, NEVER `executeWithTimeout`'s
    // abandon-on-timeout race, so the observation is always truthful (file_write is atomic).
    let payload = await tool.execute(
      arguments: arguments,
      canonicalTarget: approval.canonicalTarget
    )
    return payload.content
  }
}

// MARK: - Memory Write (Fused, Exactly-Once)

private extension ApprovedActionExecutor {
  func applyMemoryWrite(_ approval: Approval) -> ApprovedExecutionOutcome {
    guard
      let arguments = JSONValue.parse(approval.canonicalArgsJSON),
      case .parsed(let request) = MemoryWriteArguments.parse(
        arguments,
        sessionId: approval.sessionId
      )
    else {
      logger.error("memory_write approval \(approval.id) has unreadable recorded args")
      return resumeWithSyntheticObservation(
        approval,
        content: "That memory could not be saved because its details were unreadable."
      )
    }

    // Exactly-once: the item rebuilt with the SAME decoder the gate used, then insert +
    // observation update in ONE fused transaction; the placeholder guard inside
    // applyApprovedMemoryWrite makes a crash-window re-run a no-op.
    let content = """
      Saved memory item (kind \(request.item.kind.rawValue), \
      \(MemoryWriteArguments.canonicalTarget(for: request))).
      """
    do {
      let claim = try runs.applyApprovedMemoryWrite(
        runId: approval.runId,
        observationMessageId: approval.observationMessageId,
        item: request.item,
        observationContent: content,
        audit: ApprovedExecutionAudit(
          tool: approval.tool,
          argsRedacted: Self.opaqueApprovedArguments
        ),
        notResumableObservationContent: Self.notResumableObservationContent,
        now: now()
      )
      switch claim {
      case .committed:
        return ApprovedExecutionOutcome(observationContent: content, commit: .committed)
      case .alreadyResumed:
        return ApprovedExecutionOutcome(observationContent: content, commit: .ignored)
      case .runNotResumable:
        return ApprovedExecutionOutcome(
          observationContent: Self.notResumableObservationContent,
          commit: .runNotResumable
        )
      }
    } catch {
      logger.error("applyApprovedMemoryWrite failed for run \(approval.runId): \(error)")
      return ApprovedExecutionOutcome(
        observationContent: "The memory item could not be recorded.",
        commit: .storeFailed
      )
    }
  }

  /// Resumes the run with a synthetic (no side effect performed) observation: same claim-first
  /// discipline as a real execution, so a cancelled run is never resumed by an error path either.
  func resumeWithSyntheticObservation(
    _ approval: Approval,
    content: String
  ) -> ApprovedExecutionOutcome {
    do {
      let claim = try runs.claimApprovedExecution(
        runId: approval.runId,
        observationMessageId: approval.observationMessageId,
        notResumableObservationContent: Self.notResumableObservationContent,
        now: now()
      )
      switch claim {
      case .alreadyResumed:
        return ApprovedExecutionOutcome(observationContent: content, commit: .ignored)
      case .runNotResumable:
        return ApprovedExecutionOutcome(
          observationContent: Self.notResumableObservationContent,
          commit: .runNotResumable
        )
      case .committed:
        break
      }
      try runs.fillClaimedObservation(
        runId: approval.runId,
        observationMessageId: approval.observationMessageId,
        fill: ClaimedObservationFill(
          content: content,
          status: .error,
          setTainted: false,
          setPrivateData: false,
          audit: ApprovedExecutionAudit(
            tool: approval.tool,
            argsRedacted: Self.opaqueApprovedArguments
          ),
          now: now()
        )
      )
      return ApprovedExecutionOutcome(observationContent: content, commit: .committed)
    } catch {
      logger.error("synthetic observation resume failed for run \(approval.runId): \(error)")
      return ApprovedExecutionOutcome(observationContent: content, commit: .storeFailed)
    }
  }
}
