import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

/// A callback update carrying only a tapped inline button (no message/edited_message).
func callbackUpdate(
  id: Int64,
  from: Int64,
  chat: Int64? = nil,
  messageId: Int64 = 1,
  data: String?
) -> RawUpdate {
  RawUpdate(
    updateId: id,
    message: nil,
    editedMessage: nil,
    callback: RawCallback(
      callbackId: "cb\(id)",
      fromUserId: from,
      chatId: chat ?? from,
      messageId: messageId,
      data: data
    )
  )
}

/// Records `answerCallbackQuery`; the handler never disarms buttons (that is the waiter's job).
actor RecordingCallbacks: CallbackResponding {
  private(set) var answers: [(id: String, text: String?)] = []

  func answerCallbackQuery(id: String, text: String?) async throws {
    answers.append((id, text))
  }

  func editMessageReplyMarkup(chatId: Int64, messageId: Int64, replyMarkup: String?) async throws {}
}

/// A scripted `ApprovalStore`: `approval(nonce:)` returns a seeded row; `approve`/`deny` return a
/// scripted outcome and RECORD the call so tests can assert the row was (or was not) CAS-ed. All
/// other protocol members are unused by the handler and fail loudly if reached.
final class ScriptedApprovals: ApprovalStore, @unchecked Sendable {
  private let lock = NSLock()

  private let byNonce: [String: Approval]

  private let approveOutcome: ApprovalApproveOutcome
  private let denyResult: Bool
  private let throwOnResolve: Bool

  private var recordedApproveCalls: [(id: Int64, policyVersion: String)] = []
  private var recordedDenyCalls: [(id: Int64, decision: ApprovalDecision)] = []

  init(
    byNonce: [String: Approval],
    approveOutcome: ApprovalApproveOutcome,
    denyResult: Bool,
    throwOnResolve: Bool = false
  ) {
    self.byNonce = byNonce

    self.approveOutcome = approveOutcome
    self.denyResult = denyResult
    self.throwOnResolve = throwOnResolve
  }

  var approveCalls: [(id: Int64, policyVersion: String)] {
    lock.lock()
    defer { lock.unlock() }
    return recordedApproveCalls
  }

  var denyCalls: [(id: Int64, decision: ApprovalDecision)] {
    lock.lock()
    defer { lock.unlock() }
    return recordedDenyCalls
  }

  func approval(nonce: String) throws(StoreError) -> Approval? { byNonce[nonce] }
  func approval(id: Int64) throws(StoreError) -> Approval? { nil }

  func approve(
    id: Int64,
    currentPolicyVersion: String,
    now: Date
  ) throws(StoreError) -> ApprovalApproveOutcome {
    if throwOnResolve { throw StoreError.unexpected("scripted store failure") }
    lock.lock()
    defer { lock.unlock() }
    recordedApproveCalls.append((id, currentPolicyVersion))
    return approveOutcome
  }

  func deny(id: Int64, decision: ApprovalDecision, now: Date) throws(StoreError) -> Bool {
    if throwOnResolve { throw StoreError.unexpected("scripted store failure") }
    lock.lock()
    defer { lock.unlock() }
    recordedDenyCalls.append((id, decision))
    return denyResult
  }

  func sweepExpired(now: Date) throws(StoreError) -> [Approval] { [] }
  func unresolvedAtBoot() throws(StoreError) -> [Approval] { [] }
  func resolveOrphans(now: Date) throws(StoreError) -> Int { 0 }
  func approvalsHealth(now: Date) throws(StoreError) -> ApprovalsHealth {
    throw StoreError.unexpected("approvalsHealth is not used by the callback handler")
  }
}

@Suite struct ApprovalCallbackHandlerTests {
  private struct Harness {
    let handler: ApprovalCallbackHandler
    let router: MessageRouter
    let approvals: ScriptedApprovals
    let audit: RecordingAuditLog
    let callbacks: RecordingCallbacks
    let coordinator: ApprovalCoordinator
    let approval: Approval
  }

  private static let ownerId: Int64 = 42
  private static let nonce = "NONCE22CHARSEXAMPLE00"
  private static let fixedNow = Date(timeIntervalSince1970: 1_000_000)

  private static func makeApproval(id: Int64, nonce: String, ownerUserId: Int64) -> Approval {
    Approval(
      id: id,
      runId: 100,
      sessionId: 200,
      state: .pending,
      tool: "file_write",
      canonicalArgsJSON: "{\"path\":\"notes.md\"}",
      canonicalTarget: "/ws/notes.md",
      argsHash: "abc123",
      policyVersion: "POLICYV1",
      ownerUserId: ownerUserId,
      nonce: nonce,
      observationMessageId: 300,
      toolCallId: "call-1",
      reason: .askTier,
      promptMessageId: nil,
      createdTs: Date(timeIntervalSince1970: 999_000),
      expiresTs: Date(timeIntervalSince1970: 1_003_600),
      resolvedTs: nil
    )
  }

  private func approveData() -> String {
    ApprovalKeyboard.callbackData(nonce: Self.nonce, verdict: ApprovalKeyboard.approveVerdict)
  }

  private func denyData() -> String {
    ApprovalKeyboard.callbackData(nonce: Self.nonce, verdict: ApprovalKeyboard.denyVerdict)
  }

  private func makeHarness(
    allowed: [Int64] = [ownerId],
    approveOutcome: ApprovalApproveOutcome? = nil,
    denyResult: Bool = true,
    knownNonce: Bool = true,
    wireHandler: Bool = true,
    resolveThrows: Bool = false
  ) throws -> Harness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: allowed)

    let approval = Self.makeApproval(id: 7, nonce: Self.nonce, ownerUserId: Self.ownerId)
    let approvals = ScriptedApprovals(
      byNonce: knownNonce ? [Self.nonce: approval] : [:],
      approveOutcome: approveOutcome ?? .approved(approval),
      denyResult: denyResult,
      throwOnResolve: resolveThrows
    )
    let audit = RecordingAuditLog()
    let callbacks = RecordingCallbacks()
    let coordinator = ApprovalCoordinator()
    let accessControl = AccessControl(allowlist: allowlist)
    let replies = ReplySender(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      delivery: RecordingTransport(),
      logger: TestLog.silent
    )
    let handler = ApprovalCallbackHandler(
      replies: replies,
      accessControl: accessControl,
      approvals: approvals,
      audit: audit,
      coordinator: coordinator,
      callbacks: callbacks,
      currentPolicyVersion: { "POLICYV1" },
      now: { Self.fixedNow },
      logger: TestLog.silent
    )
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botUsername: "claw_bot",
      accessControl: accessControl,
      delivery: RecordingTransport(),
      turnRunner: FakeTurnRunner(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      approvalCallbacks: wireHandler ? handler : nil,
      coordinator: coordinator,
      doctor: StubDoctorReporter(),
      logger: TestLog.silent
    )
    return Harness(
      handler: handler,
      router: router,
      approvals: approvals,
      audit: audit,
      callbacks: callbacks,
      coordinator: coordinator,
      approval: approval
    )
  }

  // MARK: - Auth failures (row untouched, audited forbidden, neutral toast)

  @Test func nonAllowlistedSenderIsDeniedAndAudited() async throws {
    // given — a stranger taps a well-formed approve button
    let harness = try makeHarness()
    let update = callbackUpdate(id: 1, from: 9999, data: approveData())

    // when
    let callback = try #require(update.callback)
    let outcome = await harness.handler.handle(callback, updateId: update.updateId)

    // then — no CAS, one forbidden access audit (system actor), one neutral toast, update consumed
    #expect(outcome == .processed)
    #expect(harness.approvals.approveCalls.isEmpty)
    #expect(harness.approvals.denyCalls.isEmpty)
    let events = harness.audit.events
    #expect(events.count == 1)
    #expect(events.first?.action == .messageIn)
    #expect(events.first?.decision == "forbidden")
    #expect(events.first?.actor == .system)
    #expect(await harness.callbacks.answers.count == 1)
  }

  @Test func allowlistedNonOwnerFailsOwnerBinding() async throws {
    // given — an allowlisted user who is NOT the approval's owner taps approve
    let harness = try makeHarness(allowed: [Self.ownerId, 43])
    let update = callbackUpdate(id: 2, from: 43, data: approveData())

    // when
    let callback = try #require(update.callback)
    let outcome = await harness.handler.handle(callback, updateId: update.updateId)

    // then — owner binding fails: no CAS, forbidden audit linked to the run, one toast
    #expect(outcome == .processed)
    #expect(harness.approvals.approveCalls.isEmpty)
    let events = harness.audit.events
    #expect(events.count == 1)
    #expect(events.first?.decision == "forbidden")
    #expect(events.first?.actor == .system)
    #expect(events.first?.runId == 100)
    #expect(await harness.callbacks.answers.count == 1)
  }

  @Test func unknownNonceIsDenied() async throws {
    // given — the nonce resolves to no row
    let harness = try makeHarness(knownNonce: false)
    let update = callbackUpdate(id: 3, from: Self.ownerId, data: approveData())

    // when
    let callback = try #require(update.callback)
    let outcome = await harness.handler.handle(callback, updateId: update.updateId)

    // then — actor is `system`, not `owner`: owner-attribution requires the RESOLVED approval row
    // (`approval?.ownerUserId == callback.fromUserId` in denyAuth), and an unknown nonce resolves
    // no row — the handler has no other owner identity, so even the owner's own tap is unattributed
    #expect(outcome == .processed)
    #expect(harness.approvals.approveCalls.isEmpty)
    #expect(harness.audit.events.first?.decision == "forbidden")
    #expect(harness.audit.events.first?.actor == .system)
    #expect(await harness.callbacks.answers.count == 1)
  }

  @Test func unparseableCallbackDataIsDenied() async throws {
    // given — the owner taps but the callback_data is malformed
    let harness = try makeHarness()
    let update = callbackUpdate(id: 4, from: Self.ownerId, data: "not-a-verdict")

    // when
    let callback = try #require(update.callback)
    let outcome = await harness.handler.handle(callback, updateId: update.updateId)

    // then — never reaches the store; audited forbidden; toasted
    #expect(outcome == .processed)
    #expect(harness.approvals.approveCalls.isEmpty)
    #expect(harness.audit.events.first?.decision == "forbidden")
    #expect(await harness.callbacks.answers.count == 1)
  }

  // MARK: - Valid resolutions (CAS + coordinator signal + toast)

  @Test func validApproveCASesAndSignalsApproved() async throws {
    // given — the owner taps approve on a still-PENDING row
    let harness = try makeHarness(
      approveOutcome: .approved(
        Self.makeApproval(
          id: 7,
          nonce: Self.nonce,
          ownerUserId: Self.ownerId
        )
      )
    )
    let update = callbackUpdate(id: 5, from: Self.ownerId, data: approveData())

    // when
    let callback = try #require(update.callback)
    let outcome = await harness.handler.handle(callback, updateId: update.updateId)

    // then — approve CAS carries the recomputed policy_version; coordinator signaled .approved; no
    // handler-side audit (approvalGranted rides the store CAS, D3)
    #expect(outcome == .processed)
    #expect(harness.approvals.approveCalls.count == 1)
    #expect(harness.approvals.approveCalls.first?.id == 7)
    #expect(harness.approvals.approveCalls.first?.policyVersion == "POLICYV1")
    #expect(harness.audit.events.isEmpty)
    #expect(await harness.coordinator.awaitResolution(approvalId: 7) == .approved)
    #expect(await harness.callbacks.answers.count == 1)
  }

  @Test func validDenyCASesAndSignalsRejected() async throws {
    // given — the owner taps deny
    let harness = try makeHarness()
    let update = callbackUpdate(id: 6, from: Self.ownerId, data: denyData())

    // when
    let callback = try #require(update.callback)
    let outcome = await harness.handler.handle(callback, updateId: update.updateId)

    // then
    #expect(outcome == .processed)
    #expect(harness.approvals.approveCalls.isEmpty)
    #expect(harness.approvals.denyCalls.count == 1)
    #expect(harness.approvals.denyCalls.first?.id == 7)
    #expect(harness.approvals.denyCalls.first?.decision == .rejected)
    #expect(await harness.coordinator.awaitResolution(approvalId: 7) == .denied(.rejected))
    #expect(await harness.callbacks.answers.count == 1)
  }

  @Test func stalePolicyApproveSignalsDeniedStalePolicy() async throws {
    // given — the approve CAS finds a hash/policy mismatch
    let harness = try makeHarness(
      approveOutcome: .stalePolicy(
        Self.makeApproval(
          id: 7,
          nonce: Self.nonce,
          ownerUserId: Self.ownerId
        )
      )
    )
    let update = callbackUpdate(id: 7, from: Self.ownerId, data: approveData())

    // when
    let callback = try #require(update.callback)
    let outcome = await harness.handler.handle(callback, updateId: update.updateId)

    // then — coordinator signaled a denial with the stale_policy decision
    #expect(outcome == .processed)
    #expect(harness.approvals.approveCalls.count == 1)
    #expect(await harness.coordinator.awaitResolution(approvalId: 7) == .denied(.stalePolicy))
    #expect(await harness.callbacks.answers.count == 1)
  }

  @Test func expiredRowApproveRoutesToDenyExpired() async throws {
    // given — the approve CAS finds the row already past its deadline
    let harness = try makeHarness(approveOutcome: .expiredRow)
    let update = callbackUpdate(id: 8, from: Self.ownerId, data: approveData())

    // when
    let callback = try #require(update.callback)
    let outcome = await harness.handler.handle(callback, updateId: update.updateId)

    // then — the handler routes to deny(.expired) and signals .denied(.expired)
    #expect(outcome == .processed)
    #expect(harness.approvals.denyCalls.count == 1)
    #expect(harness.approvals.denyCalls.first?.decision == .expired)
    #expect(await harness.coordinator.awaitResolution(approvalId: 7) == .denied(.expired))
    #expect(await harness.callbacks.answers.count == 1)
  }

  @Test func alreadyResolvedApproveDoesNotSignal() async throws {
    // given — a duplicate tap lands after the row is already resolved
    let harness = try makeHarness(approveOutcome: .notPending)
    let update = callbackUpdate(id: 9, from: Self.ownerId, data: approveData())

    // when
    let callback = try #require(update.callback)
    let outcome = await harness.handler.handle(callback, updateId: update.updateId)

    // then — CAS attempted, no coordinator signal (nothing to resume), still answered
    #expect(outcome == .processed)
    #expect(harness.approvals.approveCalls.count == 1)
    #expect(harness.audit.events.isEmpty)
    #expect(await harness.callbacks.answers.count == 1)
  }

  // MARK: - Dedup + router branch

  @Test func duplicateUpdateIdIsClaimedOnce() async throws {
    // given — the same update is redelivered (same update_id)
    let harness = try makeHarness()
    let update = callbackUpdate(id: 10, from: Self.ownerId, data: approveData())
    let callback = try #require(update.callback)

    // when
    let first = await harness.handler.handle(callback, updateId: update.updateId)
    let second = await harness.handler.handle(callback, updateId: update.updateId)

    // then — the processed_updates claim dedups the redelivery; the CAS ran exactly once
    #expect(first == .processed)
    #expect(second == .skipped)
    #expect(harness.approvals.approveCalls.count == 1)
  }

  @Test func routerRoutesCallbackToHandlerAheadOfNormalize() async throws {
    // given — a router wired with the handler
    let harness = try makeHarness()
    let update = callbackUpdate(id: 11, from: Self.ownerId, data: approveData())

    // when — routed through the full MessageRouter (not the handler directly)
    let outcome = await harness.router.handle(rawUpdate: update)

    // then — the callback branch fired before IncomingMessage.normalize would have skipped it
    #expect(outcome == .processed)
    #expect(harness.approvals.approveCalls.count == 1)
  }

  @Test func routerWithoutHandlerSkipsCallback() async throws {
    // given — a router with no approval handler configured (dormant composition)
    let harness = try makeHarness(wireHandler: false)
    let update = callbackUpdate(id: 12, from: Self.ownerId, data: approveData())

    // when
    let outcome = await harness.router.handle(rawUpdate: update)

    // then — no handler, no CAS, safely skipped (cursor advances)
    #expect(outcome == .skipped)
    #expect(harness.approvals.approveCalls.isEmpty)
  }

  // MARK: - Store-failure retry (§9)

  @Test func storeFailureAnswersRetryAndLeavesRowUnresolved() async throws {
    // given — the approve CAS throws a transient store failure after the update is claimed
    let harness = try makeHarness(resolveThrows: true)
    let update = callbackUpdate(id: 13, from: Self.ownerId, data: approveData())

    // when
    let callback = try #require(update.callback)
    let outcome = await harness.handler.handle(callback, updateId: update.updateId)

    // then — §9: the owner is told to try again (the row is still PENDING and tappable, so the
    // neutral "no longer available" copy would mislead); no coordinator signal, no terminal audit
    #expect(outcome == .processed)
    let answer = try #require(await harness.callbacks.answers.first)
    #expect(answer.text == "Something went wrong — please try again.")
    #expect(harness.audit.events.isEmpty)
  }
}
