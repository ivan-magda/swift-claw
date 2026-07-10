import ClawCore
import ClawData
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

/// A scripted `ApprovalStore` for the run()-loop timing test: counts `sweepExpired` calls and
/// returns no swept rows (the loop test asserts on tick count + slept duration, not on signals —
/// those are covered by the real-store tick() tests). Every other method is loud, so the ticker
/// calling anything but `sweepExpired` fails the test instead of silently passing.
private final class RecordingApprovalStore: ApprovalStore, @unchecked Sendable {
  private let lock = NSLock()
  private var sweepCount = 0

  var sweeps: Int {
    lock.lock()
    defer { lock.unlock() }
    return sweepCount
  }

  func sweepExpired(now: Date) throws(StoreError) -> [Approval] {
    lock.lock()
    defer { lock.unlock() }
    sweepCount += 1
    return []
  }

  func approval(nonce: String) throws(StoreError) -> Approval? {
    throw StoreError.unexpected("unused by ApprovalExpiryService")
  }

  func approval(id: Int64) throws(StoreError) -> Approval? {
    throw StoreError.unexpected("unused by ApprovalExpiryService")
  }

  func approve(
    id: Int64,
    currentPolicyVersion: String,
    now: Date
  ) throws(StoreError) -> ApprovalApproveOutcome {
    throw StoreError.unexpected("unused by ApprovalExpiryService")
  }

  func deny(id: Int64, decision: ApprovalDecision, now: Date) throws(StoreError) -> Bool {
    throw StoreError.unexpected("unused by ApprovalExpiryService")
  }

  func unresolvedAtBoot() throws(StoreError) -> [Approval] {
    throw StoreError.unexpected("unused by ApprovalExpiryService")
  }

  func resolveOrphans(now: Date) throws(StoreError) -> Int {
    throw StoreError.unexpected("unused by ApprovalExpiryService")
  }

  func approvalsHealth(now: Date) throws(StoreError) -> ApprovalsHealth {
    throw StoreError.unexpected("unused by ApprovalExpiryService")
  }
}

/// Records the durations the run() loop sleeps; throwing after a real suspend ends the loop like a
/// graceful shutdown WITHOUT blocking the cooperative thread (TESTING §8 / preamble nproc=1 rule).
private final class ExpirySleepRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Duration] = []

  var durations: [Duration] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func append(_ duration: Duration) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(duration)
  }
}

@Suite struct ApprovalExpiryServiceTests {
  private struct TickFixture {
    let queue: DatabaseQueue
    let store: ApprovalStoreGRDB
    let coordinator: ApprovalCoordinator
    let service: ApprovalExpiryService
  }

  /// A fresh in-memory DB with one session (id 1); the service wraps the REAL store + a REAL
  /// coordinator so the tick() tests assert on persisted rows AND the buffered coordinator signal.
  /// The sleep double is never reached in a tick() test but still SUSPENDS before throwing.
  private func makeTickFixture(now: Date) throws -> TickFixture {
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
    let store = ApprovalStoreGRDB(writer: queue)
    let coordinator = ApprovalCoordinator()
    let service = ApprovalExpiryService(
      approvals: store,
      coordinator: coordinator,
      now: { now },
      sleep: { _ in
        try? await Task.sleep(for: .milliseconds(1))
        throw CancellationError()
      },
      logger: TestLog.silent
    )
    return TickFixture(queue: queue, store: store, coordinator: coordinator, service: service)
  }

  /// Seeds a run (approvals.run_id has an FK to runs) and returns its id.
  private func seedRun(_ queue: DatabaseQueue) throws -> Int64 {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts)
          VALUES (1, ?, ?, ?)
          """,
        arguments: [RunState.awaitingApproval.rawValue, Date(), Date()]
      )
      return db.lastInsertedRowID
    }
  }

  /// Inserts a PENDING approval with explicit epoch-second timestamps (the v8 `approvals` columns
  /// are INTEGER epochs, so the sweep's `expires_ts <= now` compare is exact integer arithmetic).
  @discardableResult
  private func seedApproval(
    _ queue: DatabaseQueue,
    runId: Int64,
    nonce: String,
    createdEpoch: Int64,
    expiresEpoch: Int64
  ) throws -> Int64 {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO approvals(run_id, session_id, state, tool, canonical_args, canonical_target,
            args_hash, policy_version, owner_user_id, nonce, observation_message_id, tool_call_id,
            reason, created_ts, expires_ts)
          VALUES (?, 1, 'PENDING', 'file_write', '{}', '/w/plan.md', 'h16', 'pv16', 7, ?, 1, 'c1',
            'ask_tier', ?, ?)
          """,
        arguments: [runId, nonce, createdEpoch, expiresEpoch]
      )
      return db.lastInsertedRowID
    }
  }

  @Test func tickExpiresPastDuePendingRowsAndSignalsTheirWaiters() async throws {
    // given — two runs: one approval already past its deadline, one still live (distinct runs so
    // the partial UNIQUE-PENDING index permits both)
    let now = Date(timeIntervalSince1970: 1_782_003_600)
    let fixture = try makeTickFixture(now: now)
    let expiredRun = try seedRun(fixture.queue)
    let liveRun = try seedRun(fixture.queue)
    let expiredId = try seedApproval(
      fixture.queue,
      runId: expiredRun,
      nonce: "n-expired",
      createdEpoch: 1_781_996_400,
      expiresEpoch: 1_782_000_000
    )
    let liveId = try seedApproval(
      fixture.queue,
      runId: liveRun,
      nonce: "n-live",
      createdEpoch: 1_782_003_000,
      expiresEpoch: 1_782_007_200
    )

    // when — one immediate sweep pass
    await fixture.service.tick()

    // then — the past-due row is EXPIRED in the DB and its waiter received denied(.expired); the
    // live row is untouched
    #expect(try fixture.store.approval(id: expiredId)?.state == .expired)
    #expect(try fixture.store.approval(id: liveId)?.state == .pending)
    #expect(await fixture.coordinator.awaitResolution(approvalId: expiredId) == .denied(.expired))
  }

  @Test func tickSignalsEverySweptRow() async throws {
    // given — two independently past-due approvals on distinct runs
    let now = Date(timeIntervalSince1970: 1_782_003_600)
    let fixture = try makeTickFixture(now: now)
    let firstRun = try seedRun(fixture.queue)
    let secondRun = try seedRun(fixture.queue)
    let firstId = try seedApproval(
      fixture.queue,
      runId: firstRun,
      nonce: "n-1",
      createdEpoch: 1_781_996_400,
      expiresEpoch: 1_782_000_000
    )
    let secondId = try seedApproval(
      fixture.queue,
      runId: secondRun,
      nonce: "n-2",
      createdEpoch: 1_781_996_400,
      expiresEpoch: 1_782_000_060
    )

    // when
    await fixture.service.tick()

    // then — every swept row got its own denied(.expired) signal and is EXPIRED in the DB
    #expect(await fixture.coordinator.awaitResolution(approvalId: firstId) == .denied(.expired))
    #expect(await fixture.coordinator.awaitResolution(approvalId: secondId) == .denied(.expired))
    #expect(try fixture.store.approval(id: firstId)?.state == .expired)
    #expect(try fixture.store.approval(id: secondId)?.state == .expired)
  }

  @Test func tickLeavesLiveRowsPendingAndSignalsNoOne() async throws {
    // given — a single approval whose deadline is still in the future
    let now = Date(timeIntervalSince1970: 1_782_003_600)
    let fixture = try makeTickFixture(now: now)
    let run = try seedRun(fixture.queue)
    let liveId = try seedApproval(
      fixture.queue,
      runId: run,
      nonce: "n-live",
      createdEpoch: 1_782_003_000,
      expiresEpoch: 1_782_007_200
    )

    // when
    await fixture.service.tick()

    // then — nothing swept: the row stays PENDING (a never-signaled id cannot be awaited without
    // hanging, so the untouched persisted row is the observable proof no waiter was signaled)
    #expect(try fixture.store.approval(id: liveId)?.state == .pending)
  }

  @Test func runTicksImmediatelyThenSleepsTheTickInterval() async throws {
    // given — a recording store and a sleep that SUSPENDS (never blocks the cooperative thread,
    // TESTING §8) then throws to end the loop like a graceful shutdown
    let store = RecordingApprovalStore()
    let recorder = ExpirySleepRecorder()
    let service = ApprovalExpiryService(
      approvals: store,
      coordinator: ApprovalCoordinator(),
      now: { Date(timeIntervalSince1970: 1_782_003_600) },
      sleep: { duration in
        try? await Task.sleep(for: .milliseconds(1))
        recorder.append(duration)
        throw CancellationError()
      },
      logger: TestLog.silent
    )

    // when — restart recovery: the first sweep happens BEFORE the first sleep
    try await service.run()

    // then
    #expect(store.sweeps == 1)
    #expect(recorder.durations == [ApprovalExpiryService.tickInterval])
  }
}
