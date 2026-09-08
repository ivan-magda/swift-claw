import ClawCore
import ClawTestSupport
import Dispatch
import Foundation
import GRDB
import Synchronization
import Testing

@testable import ClawData

@Suite struct TrialSerializationTests {
  @Test func recomputeThenResetCommitsOnlyTheSerializedOldEpochProjection() async throws {
    // given
    let gate = SQLiteTransactionGate()
    let fixture = try pooledTrialEnvironment(prefix: "claw-trial-recompute-reset", gate: gate)
    defer {
      gate.release()
      try? FileManager.default.removeItem(atPath: fixture.path)
    }
    try fixture.env.installTrial()
    let evidence = try fixture.env.sealedTrialEvidence()
    try fixture.env.resetAssignmentCache(runId: evidence.runId, state: .created)
    try await fixture.env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER hold_task16_recompute
          BEFORE UPDATE OF state ON trial_assignments
          WHEN OLD.run_id = \(evidence.runId)
          BEGIN SELECT task16_hold(); END
          """
      )
    }
    let learning = fixture.env.learning
    let jobId = fixture.env.jobId
    let now = fixture.env.now

    // when
    let recomputationTask = databaseTask {
      try learning.recomputeAssignment(runId: evidence.runId, now: now)
    }
    await gate.entered.wait()
    let resetTask = databaseTask {
      try learning.applyReset(updateId: 9_160, jobId: jobId, now: now.addingTimeInterval(1))
    }
    gate.release()
    let recomputation = try await recomputationTask.value
    let reset = try await resetTask.value

    // then — moving the projection after its writer transaction would let it cross the reset epoch.
    guard case .updated(let assignment) = recomputation else {
      Issue.record("expected the first serialized writer to refresh the old-epoch cache")
      return
    }
    guard case .applied(let receipt)? = reset.outcome else {
      Issue.record("expected reset to apply after recomputation")
      return
    }
    #expect(assignment.state == .primaryRunSettled)
    #expect(receipt.result.newEpoch == LearningEpoch(2))
    #expect(try fixture.env.currentLearningState().epoch == LearningEpoch(2))
    #expect(try fixture.env.assignmentState(runId: evidence.runId) == .primaryRunSettled)
    #expect(try fixture.env.trialState() == .closed)
  }

  @Test func resetThenRecomputeRejectsTheOldEpochWithoutWritingItsCache() async throws {
    // given
    let gate = SQLiteTransactionGate()
    let fixture = try pooledTrialEnvironment(prefix: "claw-trial-reset-recompute", gate: gate)
    defer {
      gate.release()
      try? FileManager.default.removeItem(atPath: fixture.path)
    }
    try fixture.env.installTrial()
    let evidence = try fixture.env.sealedTrialEvidence()
    try fixture.env.resetAssignmentCache(runId: evidence.runId, state: .created)
    try await fixture.env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER hold_task16_reset
          BEFORE UPDATE OF learning_epoch ON job_learning_state
          WHEN OLD.job_id = \(fixture.env.jobId)
          BEGIN SELECT task16_hold(); END
          """
      )
    }
    let learning = fixture.env.learning
    let jobId = fixture.env.jobId
    let now = fixture.env.now

    // when
    let resetTask = databaseTask {
      try learning.applyReset(updateId: 9_161, jobId: jobId, now: now.addingTimeInterval(1))
    }
    await gate.entered.wait()
    let recomputationTask = databaseTask {
      try learning.recomputeAssignment(runId: evidence.runId, now: now.addingTimeInterval(2))
    }
    gate.release()
    let reset = try await resetTask.value
    let recomputation = try await recomputationTask.value

    // then — removing the current-epoch fence lets an old assignment overwrite cache after reset.
    guard case .applied(let receipt)? = reset.outcome else {
      Issue.record("expected reset to win the serialized writer order")
      return
    }
    #expect(receipt.result.newEpoch == LearningEpoch(2))
    #expect(recomputation == .stale)
    #expect(try fixture.env.assignmentState(runId: evidence.runId) == .created)
    #expect(try fixture.env.trialState() == .closed)
  }

  @Test func admissionQueuedBehindTheThirdFireStillSeesOneLiveDrainingTrial() async throws {
    // given
    let gate = SQLiteTransactionGate()
    let fixture = try pooledTrialEnvironment(prefix: "claw-trial-admission-drain", gate: gate)
    defer {
      gate.release()
      try? FileManager.default.removeItem(atPath: fixture.path)
    }
    let admission = AdmissionStoreFixture(env: fixture.env)
    let candidate = try admission.persistedCandidate()
    try fixture.env.installTrial()
    try fixture.env.makeRepeatable()
    _ = try fixture.env.settledBoundRun()
    _ = try fixture.env.settledBoundRun()
    try await fixture.env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER hold_task16_third_fire
          BEFORE UPDATE OF consumed_assignments ON learning_trials
          WHEN NEW.consumed_assignments = 3
          BEGIN SELECT task16_hold(); END
          """
      )
    }
    let env = fixture.env

    // when
    let fireTask = databaseTask {
      try env.pendingBoundRun()
    }
    await gate.entered.wait()
    let admissionTask = databaseTask {
      try env.learning.admitCandidate(
        digest: candidate.digest,
        redactor: SecretRedactor(secretValues: []),
        now: env.now.addingTimeInterval(1)
      )
    }
    gate.release()
    _ = try await fireTask.value
    let outcome = try await admissionTask.value

    // then — an open-only lookup or index can admit a second experiment after the drain commits.
    #expect(outcome == .rejected(.trialAlreadyLive))
    #expect(try env.trialState() == .draining)
    #expect(try env.liveTrialCount() == 1)
  }
}

private struct PooledTrialEnvironment {
  let path: String
  let env: BoundRunEnvironment
}

private func databaseTask<Value: Sendable>(
  _ operation: @escaping @Sendable () throws -> Value
) -> Task<Value, any Error> {
  Task {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(with: Result(catching: operation))
      }
    }
  }
}

private func pooledTrialEnvironment(
  prefix: String,
  gate: SQLiteTransactionGate
) throws -> PooledTrialEnvironment {
  let path = makeTempDatabasePath(prefix: prefix)
  var configuration = ClawDatabase.makeConfiguration()
  configuration.prepareDatabase { db in
    db.add(
      function: DatabaseFunction("task16_hold", argumentCount: 0) { _ in
        gate.hold()
        return 0
      }
    )
  }
  let pool = try DatabasePool(path: path, configuration: configuration)
  return PooledTrialEnvironment(path: path, env: try BoundRunEnvironment.make(writer: pool))
}

private final class SQLiteTransactionGate: @unchecked Sendable {
  let entered = AsyncGate()

  private let semaphore = DispatchSemaphore(value: 0)
  private let released = Mutex(false)

  func hold() {
    entered.open()
    semaphore.wait()
  }

  func release() {
    let shouldSignal = released.withLock { state in
      guard state == false else {
        return false
      }
      state = true
      return true
    }
    if shouldSignal {
      semaphore.signal()
    }
  }
}

private extension BoundRunEnvironment {
  func trialState() throws -> LearningTrialState? {
    try queue.read { db in
      let raw = try String.fetchOne(
        db,
        sql: "SELECT state FROM learning_trials WHERE job_id = ? ORDER BY trial_id LIMIT 1",
        arguments: [jobId]
      )
      return raw.flatMap(LearningTrialState.init(rawValue:))
    }
  }

  func liveTrialCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM learning_trials WHERE state IN (?, ?)",
        arguments: [LearningTrialState.open.rawValue, LearningTrialState.draining.rawValue]
      ) ?? -1
    }
  }
}
