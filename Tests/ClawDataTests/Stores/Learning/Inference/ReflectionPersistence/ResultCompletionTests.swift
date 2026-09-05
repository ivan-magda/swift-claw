import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

extension ReflectionPersistenceTests {
  @Test func candidateCompletionCommitsArtifactSpendAndTerminalStateWithoutAdmission() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: started)
    let initialState = try env.currentLearningState()

    // when
    let committed = try env.learning.finishOperation(
      env.reflectionResult(operation: started, product: .candidate(artifact)),
      now: env.now
    )

    // then — splitting any one write out of finish would expose a succeeded partial artifact
    #expect(committed)
    #expect(try env.operationState(started.id) == .succeeded)
    #expect(try env.learningUsage(operationId: started.id).count == 1)
    #expect(try env.learning.candidateArtifact(digest: artifact.digest) == artifact)
    #expect(try env.countRows(in: "learning_candidates") == 1)
    #expect(try env.countRows(in: "learning_trials") == 0)
    #expect(try env.currentLearningState() == initialState)
  }

  @Test func noCandidateCompletionWritesOnlyACompactReceiptAndSpend() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let result = try env.noCandidate(fixture: fixture, operation: started)

    // when
    let committed = try env.learning.finishOperation(
      env.reflectionResult(operation: started, product: .noCandidate(result)),
      now: env.now
    )

    // then — persisting payload or lesson bytes would turn a negative receipt into another artifact
    #expect(committed)
    #expect(try env.operationState(started.id) == .succeeded)
    #expect(try env.learningUsage(operationId: started.id).count == 1)
    #expect(try env.countRows(in: "learning_candidates") == 0)
    let receipt = try #require(try reflectionDecision(env))
    #expect(receipt.kind == "reflection_no_candidate")
    #expect(receipt.inputs == ["carrier_digest", "operation_id", "trigger_digest"])
    #expect(receipt.result == ["result_digest"])
    #expect(receipt.algorithm == LearningAlgorithm.v1.rawValue)
  }

  @Test func artifactConstraintFailureRollsBackClosureAndSpend() throws {
    // given — the same immutable artifact already exists, forcing the terminal transaction to fail
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let artifact = try env.candidate(fixture: fixture, operation: started)
    try env.queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(db, artifact: artifact, now: env.now)
    }

    // when
    let failure: StoreError?
    do {
      _ = try env.learning.finishOperation(
        env.reflectionResult(operation: started, product: .candidate(artifact)),
        now: env.now
      )
      failure = nil
    } catch let error {
      failure = error
    }

    // then — committing operation or usage before the candidate INSERT would leave a torn result
    #expect(failure != nil)
    #expect(try env.operationState(started.id) == .started)
    #expect(try env.learningUsage(operationId: started.id).isEmpty)
    #expect(try env.countRows(in: "learning_candidates") == 1)
  }

  @Test func noCandidateConstraintFailureRollsBackClosureAndSpend() throws {
    // given — a database-level failure occurs at the final receipt insert
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let result = try env.noCandidate(fixture: fixture, operation: started)
    try env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_reflection_receipt BEFORE INSERT ON learning_decisions
          BEGIN SELECT RAISE(ABORT, 'forced receipt failure'); END
          """
      )
    }

    // when
    let failure: StoreError?
    do {
      _ = try env.learning.finishOperation(
        env.reflectionResult(operation: started, product: .noCandidate(result)),
        now: env.now
      )
      failure = nil
    } catch let error {
      failure = error
    }

    // then — committing closure or spend before the receipt would tear null-result completion
    #expect(failure != nil)
    #expect(try env.operationState(started.id) == .started)
    #expect(try env.learningUsage(operationId: started.id).isEmpty)
    #expect(try env.countRows(in: "learning_decisions") == 0)
  }

  @Test func interruptedReflectorKeepsTheProviderRecoverySuccessorGeneration() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let fixture = try env.reflectionFixture()
    let started = try env.startReflector(fixture)
    let key = started.key

    // when
    _ = try env.learning.reconcileOperationsAtBoot(now: env.now)
    let successor = try #require(try env.learning.claimOperation(key, now: env.now))

    // then — removing M1 recovery would strand an ambiguous provider-level attempt forever
    #expect(try env.operationState(started.id) == .interruptedUnknown)
    #expect(successor.attemptGeneration == 2)
    #expect(successor.supersedes == started.id)
  }
}

// MARK: - Test Reads

private extension ReflectionPersistenceTests {
  struct DecisionRow {
    let kind: String
    let inputs: Set<String>
    let result: Set<String>
    let algorithm: String
  }

  func reflectionDecision(_ env: BoundRunEnvironment) throws -> DecisionRow? {
    try env.queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT kind, inputs, result, algorithm FROM learning_decisions"
        )
      else {
        return nil
      }
      let inputsJSON = try JSONSerialization.jsonObject(with: Data((row["inputs"] as String).utf8))
      let resultJSON = try JSONSerialization.jsonObject(with: Data((row["result"] as String).utf8))
      guard
        let inputs = inputsJSON as? [String: Any],
        let result = resultJSON as? [String: Any]
      else {
        throw StoreError.unexpected("reflection decision is not a pair of objects")
      }
      return DecisionRow(
        kind: row["kind"],
        inputs: Set(inputs.keys),
        result: Set(result.keys),
        algorithm: row["algorithm"]
      )
    }
  }
}
