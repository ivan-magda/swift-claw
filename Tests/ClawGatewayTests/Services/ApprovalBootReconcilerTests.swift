import ClawAgent
import ClawCore
import ClawGateway
import Foundation
import GRDB
import Testing

// `@testable` is required for the seed helper: `ApprovalStoreGRDB.insertApproval` (Task 06) is an
// internal db-scoped static, not `public`, so a plain `import ClawData` can't reach it.
@testable import ClawData

// The time limit converts a rendezvous regression (a park that never happens) into a bounded
// failure — the spy's continuation waits would otherwise hang the whole test run silently.
@Suite(.timeLimit(.minutes(1))) struct ApprovalBootReconcilerTests {
  /// Records every `park` and models the real waiter: it registers with the coordinator and awaits
  /// resolution, so the lane stays held until the row resolves. All rendezvous are continuation-based
  /// (never a sleep or a spin) so the suite is deterministic at nproc=1.
  private actor ParkingSpy: ApprovalParking {
    struct Call: Sendable, Equatable {
      let approvalId: Int64
      let runId: Int64
      let sessionId: Int64
      let chatId: Int64
      let revalidate: Bool
    }

    private let coordinator: ApprovalCoordinator
    private var bufferedCalls: [Call] = []
    private var callWaiters: [CheckedContinuation<Call, Never>] = []
    private var resolvedSignals: [Int64: ApprovalSignal] = [:]
    private var resolutionWaiters: [Int64: [CheckedContinuation<ApprovalSignal, Never>]] = [:]

    init(coordinator: ApprovalCoordinator) {
      self.coordinator = coordinator
    }

    func park(
      approvalId: Int64,
      runId: Int64,
      sessionId: Int64,
      chatId: Int64,
      revalidatePolicyOnApprove: Bool
    ) async {
      let call = Call(
        approvalId: approvalId,
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        revalidate: revalidatePolicyOnApprove
      )
      deliver(call)
      // `awaitResolution` returns nil only on cancellation (never in these tests); guard mirrors the
      // real `ApprovalWaiter.park`, which exits cleanly on a nil resolution.
      guard let signal = await coordinator.awaitResolution(approvalId: approvalId) else {
        return
      }
      recordResolution(signal, for: approvalId)
    }

    /// Suspends until the next `park` lands — the deterministic "the boot-parked waiter registered
    /// and is holding the lane" checkpoint the tests synchronize on.
    func nextParkCall() async -> Call {
      if !bufferedCalls.isEmpty {
        return bufferedCalls.removeFirst()
      }
      return await withCheckedContinuation { continuation in
        callWaiters.append(continuation)
      }
    }

    /// Suspends until the parked waiter for `approvalId` observes its coordinator resolution.
    func awaitParkResolution(of approvalId: Int64) async -> ApprovalSignal {
      if let signal = resolvedSignals[approvalId] {
        return signal
      }
      return await withCheckedContinuation { continuation in
        resolutionWaiters[approvalId, default: []].append(continuation)
      }
    }

    private(set) var parkCallCount = 0

    private func deliver(_ call: Call) {
      parkCallCount += 1
      if callWaiters.isEmpty {
        bufferedCalls.append(call)
      } else {
        callWaiters.removeFirst().resume(returning: call)
      }
    }

    private func recordResolution(_ signal: ApprovalSignal, for approvalId: Int64) {
      resolvedSignals[approvalId] = signal
      let waiters = resolutionWaiters[approvalId] ?? []
      resolutionWaiters[approvalId] = nil
      for waiter in waiters {
        waiter.resume(returning: signal)
      }
    }
  }

  /// A plain lane citizen enqueued behind a re-parked waiter — proves the FIFO queue-behind contract.
  private actor FollowerFlag {
    private(set) var ran = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markRan() {
      ran = true
      for waiter in waiters {
        waiter.resume()
      }
      waiters = []
    }

    func awaitRan() async {
      if ran {
        return
      }
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }
  }

  private struct Fixture {
    let queue: DatabaseQueue
    let store: ApprovalStoreGRDB
    let sessionId: Int64
    let lanes: SessionLaneRegistry
    let coordinator: ApprovalCoordinator
    let spy: ParkingSpy

    func reconciler(now instant: Date) -> ApprovalBootReconciler {
      ApprovalBootReconciler(
        approvals: store,
        runs: RunStoreGRDB(writer: queue),
        lanes: lanes,
        coordinator: coordinator,
        waiter: spy,
        now: { instant },
        logger: TestLog.silent
      )
    }

    func seedRun(state: String) throws -> Int64 {
      try queue.write { db in
        try db.execute(
          sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (1, ?, ?, ?)",
          arguments: [state, Date(), Date()]
        )
        return db.lastInsertedRowID
      }
    }

    @discardableResult
    func insertApproval(
      runId: Int64,
      nonce: String,
      createdTs: Date,
      expiresTs: Date
    ) throws -> Int64 {
      let canonicalArgsJSON = #"{"path":"/w/plan.md"}"#
      // Production's suspend commit always inserts the placeholder observation row the approval
      // points back at (§5.3), and `unresolvedAtBoot`'s crash-window arm keys on that placeholder
      // still being unfilled — a dangling observation id would make the row invisible at boot.
      return try queue.write { db in
        try db.execute(
          sql: """
            INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
            VALUES (1, ?, 'tool', ?, 'untrusted', ?, 'c1')
            """,
          arguments: [runId, RunStoreGRDB.placeholderObservationContent, Date()]
        )
        let observationMessageId = db.lastInsertedRowID
        let newApproval = NewApproval(
          runId: runId,
          sessionId: 1,
          tool: "file_write",
          canonicalArgsJSON: canonicalArgsJSON,
          canonicalTarget: "/w/plan.md",
          argsHash: ApprovalArgsHash.sha256Hex(canonicalArgsJSON),
          policyVersion: "pv16",
          ownerUserId: 7,
          nonce: nonce,
          observationMessageId: observationMessageId,
          toolCallId: "c1",
          reason: .askTier,
          createdTs: createdTs,
          expiresTs: expiresTs
        )
        return try ApprovalStoreGRDB.insertApproval(db, newApproval)
      }
    }

    func audits() throws -> [(action: String, decision: String)] {
      try queue.read { db in
        try Row.fetchAll(db, sql: "SELECT action, decision FROM audit_events ORDER BY id")
          .map { row in (action: row["action"], decision: row["decision"]) }
      }
    }

    func approvalState(_ id: Int64) throws -> ApprovalState? {
      try store.approval(id: id)?.state
    }
  }

  private func makeFixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:7', ?, ?, 0)
          """,
        arguments: [Date(), Date()]
      )
    }
    let coordinator = ApprovalCoordinator()
    return Fixture(
      queue: queue,
      store: ApprovalStoreGRDB(writer: queue),
      sessionId: 1,
      lanes: SessionLaneRegistry(),
      coordinator: coordinator,
      spy: ParkingSpy(coordinator: coordinator)
    )
  }

  @Test func approvedClaimedRunIsSettledInPlaceWithoutAPark() async throws {
    // given — the §6.6 claimed crash window after the orphan sweep: the claim committed and the
    // process died before the result record, so boot finds run FAILED + APPROVED row + placeholder
    let env = try makeFixture()
    let claimedRun = try env.seedRun(state: RunState.failed.rawValue)
    let now = Date(timeIntervalSince1970: 1_782_000_000)
    let approvalId = try env.insertApproval(
      runId: claimedRun,
      nonce: "n-claimed",
      createdTs: now,
      expiresTs: now.addingTimeInterval(3600)
    )
    try await env.queue.write { db in
      try db.execute(
        sql: "UPDATE approvals SET state = 'APPROVED' WHERE id = ?",
        arguments: [approvalId]
      )
    }

    // when
    await env.reconciler(now: now).reconcile()

    // then — settled in place, NO waiter park (there is nothing to resume): the placeholder is
    // resolved with the unknown-outcome note and the owner notice is enqueued UNCONDITIONALLY —
    // the run's sent approval prompt suppresses the generic degradation notice, so this is the
    // only signal the owner gets
    #expect(await env.spy.parkCallCount == 0)
    let observation = try await env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT content FROM messages WHERE run_id = ?",
        arguments: [claimedRun]
      )
    }
    #expect(observation?.contains("restarted") == true)
    let notice = try await env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT payload FROM outbound_deliveries WHERE run_id = ? AND status = 'PENDING'",
        arguments: [claimedRun]
      )
    }
    #expect(notice?.contains("file_write") == true)
  }

  @Test func terminalRunPendingApprovalIsResolvedWithNoOrphan() async throws {
    // given — a PENDING approval whose run already FAILED (a restart orphan) plus one genuinely
    // parked approval, so we prove only the orphan is cleaned and the parked row is left alone
    let env = try makeFixture()
    let failedRun = try env.seedRun(state: RunState.failed.rawValue)
    let parkedRun = try env.seedRun(state: RunState.awaitingApproval.rawValue)
    let now = Date(timeIntervalSince1970: 1_782_000_000)
    let orphanId = try env.insertApproval(
      runId: failedRun,
      nonce: "n-orphan",
      createdTs: now,
      expiresTs: now.addingTimeInterval(3600)
    )
    let keptId = try env.insertApproval(
      runId: parkedRun,
      nonce: "n-kept",
      createdTs: now,
      expiresTs: now.addingTimeInterval(3600)
    )

    // when — resolveOrphans runs before unresolvedAtBoot, so the parked row is never mistaken for one
    await env.reconciler(now: now).reconcile()
    _ = await env.spy.nextParkCall()

    // then — the terminal-run orphan is REJECTED/cancelled; the parked row stays PENDING for re-park
    #expect(try env.approvalState(orphanId) == .rejected)
    #expect(try env.approvalState(keptId) == .pending)
    #expect(
      try env.audits()
        .contains {
          $0 == (AuditAction.approvalDenied.rawValue, ApprovalDecision.cancelled.rawValue)
        }
    )
  }

  @Test func unexpiredPendingReParksAndResolvesViaTheBootParkedWaiter() async throws {
    // given — one unexpired PENDING approval on an AWAITING_APPROVAL run (the reopened suspended DB)
    let env = try makeFixture()
    let runId = try env.seedRun(state: RunState.awaitingApproval.rawValue)
    let now = Date(timeIntervalSince1970: 1_782_000_000)
    let approvalId = try env.insertApproval(
      runId: runId,
      nonce: "n-live",
      createdTs: now,
      expiresTs: now.addingTimeInterval(3600)
    )

    // when — boot re-parks the lane
    await env.reconciler(now: now).reconcile()
    let call = await env.spy.nextParkCall()

    // then — re-parked on the run's session lane, chatId = the approval's delivery chat (§4.4), and
    // NOT under crash-window re-validation (the row is still PENDING)
    #expect(call.approvalId == approvalId)
    #expect(call.runId == runId)
    #expect(call.sessionId == env.sessionId)
    #expect(call.chatId == 7)
    #expect(call.revalidate == false)
    #expect(try env.approvalState(approvalId) == .pending)

    // and — a live callback (approve CAS + coordinator signal) still resolves through the
    // boot-parked waiter after restart: buttons survive the reboot
    let outcome = try env.store.approve(id: approvalId, currentPolicyVersion: "pv16", now: now)
    guard case .approved = outcome else {
      Issue.record("expected the callback approve CAS to commit, got \(outcome)")
      return
    }
    await env.coordinator.signal(approvalId: approvalId, .approved)
    #expect(await env.spy.awaitParkResolution(of: approvalId) == .approved)
  }

  @Test func aPlainMessageQueuesBehindTheReParkedLane() async throws {
    // given — an unexpired parked approval, re-parked at boot; the waiter now holds the session lane
    let env = try makeFixture()
    let runId = try env.seedRun(state: RunState.awaitingApproval.rawValue)
    let now = Date(timeIntervalSince1970: 1_782_000_000)
    let approvalId = try env.insertApproval(
      runId: runId,
      nonce: "n-fifo",
      createdTs: now,
      expiresTs: now.addingTimeInterval(3600)
    )
    await env.reconciler(now: now).reconcile()
    _ = await env.spy.nextParkCall()

    // when — a plain message lands on the SAME session lane after the restart
    let follower = FollowerFlag()
    let lane = await env.lanes.actor(for: env.sessionId)
    await lane.enqueue(runId: runId &+ 1_000) { await follower.markRan() }

    // then — it cannot run until the parked approval resolves (FIFO queue-behind survives restart):
    // the follower's task chains behind the still-suspended waiter task on the lane
    #expect(await follower.ran == false)

    // and — once the approval resolves, the queued message runs
    await env.coordinator.signal(approvalId: approvalId, .approved)
    await follower.awaitRan()
    #expect(await follower.ran == true)
  }

  @Test func expiredPendingIsSweptToDenyAndDrivesTheParkedWaiter() async throws {
    // given — a PENDING approval whose expires_ts already passed while the process was down
    let env = try makeFixture()
    let runId = try env.seedRun(state: RunState.awaitingApproval.rawValue)
    let now = Date(timeIntervalSince1970: 1_782_010_000)
    let approvalId = try env.insertApproval(
      runId: runId,
      nonce: "n-expired",
      createdTs: now.addingTimeInterval(-7200),
      expiresTs: now.addingTimeInterval(-60)
    )

    // when
    await env.reconciler(now: now).reconcile()
    let call = await env.spy.nextParkCall()

    // then — the §6.4 expiry path: CAS PENDING→EXPIRED + approvalDenied/expired audited here, and the
    // parked waiter consumes the buffered denial so it can drive the run AWAITING_APPROVAL→FAILED
    #expect(call.revalidate == false)
    #expect(try env.approvalState(approvalId) == .expired)
    #expect(await env.spy.awaitParkResolution(of: approvalId) == .denied(.expired))
    #expect(
      try env.audits()
        .contains { $0 == (AuditAction.approvalDenied.rawValue, ApprovalDecision.expired.rawValue) }
    )
  }

  @Test func approvedAwaitingRunReParksUnderCrashWindowRevalidation() async throws {
    // given — the §6.5 crash window: the row was granted, the process died before execution, so boot
    // finds an APPROVED row on an AWAITING_APPROVAL run
    let env = try makeFixture()
    let runId = try env.seedRun(state: RunState.awaitingApproval.rawValue)
    let now = Date(timeIntervalSince1970: 1_782_000_000)
    let approvalId = try env.insertApproval(
      runId: runId,
      nonce: "n-crash",
      createdTs: now,
      expiresTs: now.addingTimeInterval(3600)
    )
    try await env.queue.write { db in
      try db.execute(
        sql: "UPDATE approvals SET state = 'APPROVED' WHERE id = ?",
        arguments: [approvalId]
      )
    }

    // when
    await env.reconciler(now: now).reconcile()
    let call = await env.spy.nextParkCall()

    // then — re-parked with revalidatePolicyOnApprove true and the .approved signal buffered, so the
    // waiter re-validates policy_version before executing (or fails the RUN on mismatch, §6.5). The
    // row STAYS APPROVED — the boot re-validation is the waiter's job, never the reconciler's
    #expect(call.revalidate == true)
    #expect(try env.approvalState(approvalId) == .approved)
    #expect(await env.spy.awaitParkResolution(of: approvalId) == .approved)
  }
}

// MARK: - Deny-Side Crash Window

extension ApprovalBootReconcilerTests {
  @Test func rejectedAwaitingRunIsReParkedWithTheBufferedDenial() async throws {
    // given — the deny-side crash window: the reject CAS (+ its approvalDenied audit) committed,
    // but the process died before the waiter's observation-fill/run-fail commit, so boot finds a
    // REJECTED approval on a still-AWAITING_APPROVAL run
    let env = try makeFixture()
    let runId = try env.seedRun(state: RunState.awaitingApproval.rawValue)
    let now = Date(timeIntervalSince1970: 1_782_000_000)
    let approvalId = try env.insertApproval(
      runId: runId,
      nonce: "n-rejected",
      createdTs: now,
      expiresTs: now.addingTimeInterval(3600)
    )
    try await env.queue.write { db in
      try db.execute(
        sql: "UPDATE approvals SET state = 'REJECTED' WHERE id = ?",
        arguments: [approvalId]
      )
    }

    // when
    await env.reconciler(now: now).reconcile()
    let call = await env.spy.nextParkCall()

    // then — finalized, not ignored: re-parked without re-validation and the generic denial
    // buffered so the waiter drives the run AWAITING_APPROVAL→FAILED. The row STAYS REJECTED and
    // no new audit lands — the pre-crash CAS already recorded both
    #expect(call.approvalId == approvalId)
    #expect(call.revalidate == false)
    #expect(await env.spy.awaitParkResolution(of: approvalId) == .denied(.rejected))
    #expect(try env.approvalState(approvalId) == .rejected)
    #expect(try env.audits().isEmpty)
  }

  @Test func expiredAwaitingRunIsReParkedWithTheBufferedDenial() async throws {
    // given — the same deny-side crash window for a row the expiry CAS resolved before the crash:
    // an EXPIRED approval on a still-AWAITING_APPROVAL run
    let env = try makeFixture()
    let runId = try env.seedRun(state: RunState.awaitingApproval.rawValue)
    let now = Date(timeIntervalSince1970: 1_782_010_000)
    let approvalId = try env.insertApproval(
      runId: runId,
      nonce: "n-expired-cas",
      createdTs: now.addingTimeInterval(-7200),
      expiresTs: now.addingTimeInterval(-60)
    )
    try await env.queue.write { db in
      try db.execute(
        sql: "UPDATE approvals SET state = 'EXPIRED' WHERE id = ?",
        arguments: [approvalId]
      )
    }

    // when
    await env.reconciler(now: now).reconcile()
    let call = await env.spy.nextParkCall()

    // then — the buffered denial carries .expired; the row stays EXPIRED with no re-CAS/re-audit
    #expect(call.approvalId == approvalId)
    #expect(call.revalidate == false)
    #expect(await env.spy.awaitParkResolution(of: approvalId) == .denied(.expired))
    #expect(try env.approvalState(approvalId) == .expired)
    #expect(try env.audits().isEmpty)
  }
}
