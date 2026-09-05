import ClawCore
import GRDB
import Testing

@testable import ClawData

@Suite struct AdmissionStateStoreTests {
  @Test(arguments: LearningTrialState.allCases)
  func everyExistingTrialStateReplaysTheImmutableReceipt(_ state: LearningTrialState) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let receipt = try #require(admitted.admissionReceipt)
    try fixture.setTrialState(receipt.trialId, state: state)
    let before = try fixture.rowCounts()

    // when
    let replay = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now.addingTimeInterval(60)
    )

    // then — interpreting a terminal trial as closed replacement loses admission idempotency.
    #expect(replay.admissionReceipt == receipt)
    #expect(try fixture.rowCounts() == before)
  }

  @Test func corruptedAdmissionReceiptFailsClosedWithoutWriting() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let outcome = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    _ = try #require(outcome.admissionReceipt)
    try fixture.corruptAdmissionReceipt()
    let before = try fixture.rowCounts()

    // when / then — returning a receipt reconstructed only from the trial hides decision damage.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.admitCandidate(
        digest: artifact.digest,
        redactor: SecretRedactor(secretValues: []),
        now: fixture.env.now
      )
    }
    #expect(try fixture.rowCounts() == before)
  }

  @Test func admissionDecisionWithoutItsTrialFailsClosedWithoutWriting() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let receipt = try #require(admitted.admissionReceipt)
    try fixture.removeTrial(receipt.trialId)
    let before = try fixture.rowCounts()

    // when / then — skipping the orphan-decision gate would reinterpret a damaged replay.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.admitCandidate(
        digest: artifact.digest,
        redactor: SecretRedactor(secretValues: []),
        now: fixture.env.now
      )
    }
    #expect(try fixture.rowCounts() == before)
  }

  @Test func noncanonicalAdmissionInputsFailClosedWithoutWriting() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    _ = try #require(admitted.admissionReceipt)
    try fixture.makeAdmissionInputsNoncanonical(candidate: artifact.digest)
    let before = try fixture.rowCounts()

    // when / then — decode-only replay accepts bytes outside the immutable receipt contract.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.admitCandidate(
        digest: artifact.digest,
        redactor: SecretRedactor(secretValues: []),
        now: fixture.env.now
      )
    }
    #expect(try fixture.rowCounts() == before)
  }

  @Test(arguments: AdmissionReplayCorruption.allCases)
  func replayRequiresEveryTrialAndDecisionIdentity(_ corruption: AdmissionReplayCorruption) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let receipt = try #require(admitted.admissionReceipt)
    try fixture.applyReplayCorruption(corruption, receipt: receipt)
    let before = try fixture.rowCounts()

    // when / then — replay must read the immutable receipt, not synthesize it from a loose row.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.admitCandidate(
        digest: artifact.digest,
        redactor: SecretRedactor(secretValues: []),
        now: fixture.env.now
      )
    }
    #expect(try fixture.rowCounts() == before)
  }

  @Test(arguments: AdmissionBindingMutation.allCases)
  func durableAdmissionWiresEveryCurrentBindingGate(_ mutation: AdmissionBindingMutation) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    try fixture.apply(mutation, artifact: artifact)

    // when
    let outcome = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — pure policy coverage cannot detect a dropped database-to-context projection.
    #expect(outcome == .rejected(mutation.expected))
    #expect(try fixture.env.countRows(in: "learning_trials") == 0)
  }

  @Test func aPausedRecurringJobStillAdmitsThroughTheDurableSeam() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    try fixture.setJobStatus(.paused)

    // when
    let outcome = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — treating paused as cancelled would discard a valid owner-controlled experiment.
    #expect(outcome.admissionReceipt != nil)
  }
}

enum AdmissionBindingMutation: CaseIterable, Sendable {
  case noRecurrence
  case cancelled
  case epoch
  case baseDigest
  case baseRevision
  case feedbackRevision
  case sourceSupport

  var expected: AdmissionRejection {
    switch self {
    case .noRecurrence, .cancelled:
      .jobNotRepeatable
    case .epoch:
      .staleEpoch
    case .baseDigest:
      .staleBaseDigest
    case .baseRevision:
      .staleBaseRevision
    case .feedbackRevision:
      .staleFeedbackRevision
    case .sourceSupport:
      .sourceBindingsChanged
    }
  }
}

enum AdmissionReplayCorruption: CaseIterable, Sendable {
  case trialJob
  case trialEpoch
  case trialBase
  case trialCandidate
  case trialAlgorithm
  case decisionJob
  case decisionEpoch
  case decisionAlgorithm
  case decisionInputs
  case resultCandidate
  case resultReplacement
  case resultTrial
  case resultGeneration
}

private extension AdmissionOutcome {
  var admissionReceipt: AdmissionReceipt? {
    guard case .admitted(let receipt) = self else {
      return nil
    }
    return receipt
  }
}

extension AdmissionStoreFixture {
  struct RowCounts: Equatable {
    let lessons: Int
    let candidates: Int
    let trials: Int
    let decisions: Int
    let audits: Int
  }

  func rowCounts() throws -> RowCounts {
    RowCounts(
      lessons: try env.countRows(in: "lesson_sets"),
      candidates: try env.countRows(in: "learning_candidates"),
      trials: try env.countRows(in: "learning_trials"),
      decisions: try env.countRows(in: "learning_decisions"),
      audits: try admissionAuditCount()
    )
  }
}

private extension AdmissionStoreFixture {
  func removeTrial(_ trialId: Int64) throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = NULL WHERE job_id = ?",
        arguments: [env.jobId]
      )
      try db.execute(sql: "DELETE FROM learning_trials WHERE trial_id = ?", arguments: [trialId])
    }
  }

  func makeAdmissionInputsNoncanonical(candidate: CandidateDigest) throws {
    try env.queue.write { db in
      let inputs = #"{"candidate_digest":"\#(candidate.rawValue)" }"#
      try db.execute(
        sql: "UPDATE learning_decisions SET inputs = ? WHERE kind = ?",
        arguments: [inputs, AdmissionReceipt.kind]
      )
    }
  }

  func setTrialState(_ trialId: Int64, state: LearningTrialState) throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE learning_trials SET state = ? WHERE trial_id = ?",
        arguments: [state.rawValue, trialId]
      )
    }
  }

  func corruptAdmissionReceipt() throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE learning_decisions SET result = ? WHERE kind = ?",
        arguments: [#"{"candidate_digest":"wrong"}"#, AdmissionReceipt.kind]
      )
    }
  }

  func applyReplayCorruption(
    _ corruption: AdmissionReplayCorruption,
    receipt: AdmissionReceipt
  ) throws {
    try env.queue.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
      switch corruption {
      case .trialJob:
        try db.execute(
          sql: "UPDATE learning_trials SET job_id = job_id + 1 WHERE trial_id = ?",
          arguments: [receipt.trialId]
        )
      case .trialEpoch:
        try db.execute(
          sql: "UPDATE learning_trials SET learning_epoch = 2 WHERE trial_id = ?",
          arguments: [receipt.trialId]
        )
      case .trialBase:
        try db.execute(
          sql: "UPDATE learning_trials SET base_digest = ? WHERE trial_id = ?",
          arguments: ["wrong-base", receipt.trialId]
        )
      case .trialCandidate:
        try db.execute(
          sql: "UPDATE learning_trials SET candidate_digest = ? WHERE trial_id = ?",
          arguments: ["wrong-candidate", receipt.trialId]
        )
      case .trialAlgorithm:
        try db.execute(
          sql: "UPDATE learning_trials SET algorithm = ? WHERE trial_id = ?",
          arguments: ["wrong-algorithm", receipt.trialId]
        )
      case .decisionJob:
        try db.execute(
          sql: "UPDATE learning_decisions SET job_id = job_id + 1 WHERE kind = ?",
          arguments: [AdmissionReceipt.kind]
        )
      case .decisionEpoch:
        try db.execute(
          sql: "UPDATE learning_decisions SET learning_epoch = 2 WHERE kind = ?",
          arguments: [AdmissionReceipt.kind]
        )
      case .decisionAlgorithm:
        try db.execute(
          sql: "UPDATE learning_decisions SET algorithm = ? WHERE kind = ?",
          arguments: ["wrong-algorithm", AdmissionReceipt.kind]
        )
      case .decisionInputs:
        try db.execute(
          sql: "UPDATE learning_decisions SET inputs = ? WHERE kind = ?",
          arguments: [#"{"candidate_digest":"wrong-candidate"}"#, AdmissionReceipt.kind]
        )
      case .resultCandidate, .resultReplacement, .resultTrial, .resultGeneration:
        let altered = AdmissionReceipt(
          candidateDigest:
            corruption == .resultCandidate
            ? CandidateDigest(rawValue: "wrong-candidate") : receipt.candidateDigest,
          replacementDigest:
            corruption == .resultReplacement
            ? LessonSetDigest(rawValue: "wrong-replacement") : receipt.replacementDigest,
          trialId: corruption == .resultTrial ? receipt.trialId + 1 : receipt.trialId,
          generation: corruption == .resultGeneration ? receipt.generation + 1 : receipt.generation
        )
        let bytes = try CanonicalJSON.data(encoding: altered)
        guard let result = String(bytes: bytes, encoding: .utf8) else {
          throw StoreError.unexpected("fixture receipt was not UTF-8")
        }
        try db.execute(
          sql: "UPDATE learning_decisions SET result = ? WHERE kind = ?",
          arguments: [result, AdmissionReceipt.kind]
        )
      }
    }
  }

  func setJobStatus(_ status: ScheduledJobStatus) throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE scheduled_jobs SET status = ? WHERE id = ?",
        arguments: [status.rawValue, env.jobId]
      )
    }
  }

  func apply(_ mutation: AdmissionBindingMutation, artifact: CandidateArtifact) throws {
    try env.queue.write { db in
      switch mutation {
      case .noRecurrence:
        try db.execute(
          sql: "UPDATE scheduled_jobs SET recurrence = NULL WHERE id = ?",
          arguments: [env.jobId]
        )
      case .cancelled:
        try db.execute(
          sql: "UPDATE scheduled_jobs SET status = ? WHERE id = ?",
          arguments: [ScheduledJobStatus.cancelled.rawValue, env.jobId]
        )
      case .epoch:
        try db.execute(
          sql: "UPDATE job_learning_state SET learning_epoch = 2 WHERE job_id = ?",
          arguments: [env.jobId]
        )
      case .baseDigest:
        try db.execute(
          sql: "UPDATE job_learning_state SET stable_lesson_set_digest = ? WHERE job_id = ?",
          arguments: [artifact.replacement.digest.rawValue, env.jobId]
        )
      case .baseRevision:
        try db.execute(
          sql: "UPDATE job_learning_state SET stable_revision = 1 WHERE job_id = ?",
          arguments: [env.jobId]
        )
      case .feedbackRevision:
        try db.execute(
          sql: "UPDATE job_learning_state SET feedback_revision = 1 WHERE job_id = ?",
          arguments: [env.jobId]
        )
      case .sourceSupport:
        try db.execute(
          sql: "UPDATE learning_evaluations SET outcome = ?, issue_codes = '[]' WHERE job_id = ?",
          arguments: [EvaluatorOutcome.noIssue.rawValue, env.jobId]
        )
      }
    }
  }
}
