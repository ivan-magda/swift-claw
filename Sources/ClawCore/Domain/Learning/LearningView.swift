import Foundation

/// The scheduled-job fields the owner view may render. Prompt and recurrence bytes stay private
/// to the scheduler; the learning surface needs only identity and display context.
public struct LearningJobIdentity: Sendable, Equatable {
  public let jobId: Int64
  public let label: String
  public let status: ScheduledJobStatus
  public let timezone: String

  public init(jobId: Int64, label: String, status: ScheduledJobStatus, timezone: String) {
    self.jobId = jobId
    self.label = label
    self.status = status
    self.timezone = timezone
  }
}

/// The bounded identity retained when a damaged job cannot be decoded safely.
public struct UnreadableLearningJob: Sendable, Equatable {
  public let jobId: Int64
  public let validatedLabel: String?

  public init(jobId: Int64, validatedLabel: String?) {
    self.jobId = jobId
    self.validatedLabel = validatedLabel
  }
}

/// A non-authoritative mismatch that can be reported without hiding authoritative state.
public enum LearningViewWarning: Sendable, Equatable {
  case trialPointerMismatch
}

/// Current assignment facts projected from authoritative source rows in one read snapshot.
public struct LearningTrialCounts: Sendable, Equatable {
  public let consumed: Int
  public let maximum: Int
  public let positive: Int
  public let negative: Int
  public let neutral: Int
  public let unresolved: Int

  public init(
    consumed: Int,
    maximum: Int,
    positive: Int,
    negative: Int,
    neutral: Int,
    unresolved: Int
  ) {
    self.consumed = consumed
    self.maximum = maximum
    self.positive = positive
    self.negative = negative
    self.neutral = neutral
    self.unresolved = unresolved
  }
}

/// One authoritative open-or-draining trial and the immutable candidate identities it exposes.
public struct LearningTrialView: Sendable, Equatable {
  public let trialId: Int64
  public let epoch: LearningEpoch
  public let generation: Int
  public let state: LearningTrialState
  public let candidateDigest: CandidateDigest
  public let baseDigest: LessonSetDigest
  public let baseRevision: StableRevision
  public let replacementDigest: LessonSetDigest
  public let counts: LearningTrialCounts
  public let assignmentDeadline: Date
  public let decisionDeadline: Date

  public init(  // swiftlint:disable:this function_parameter_count
    trialId: Int64,
    epoch: LearningEpoch,
    generation: Int,
    state: LearningTrialState,
    candidateDigest: CandidateDigest,
    baseDigest: LessonSetDigest,
    baseRevision: StableRevision,
    replacementDigest: LessonSetDigest,
    counts: LearningTrialCounts,
    assignmentDeadline: Date,
    decisionDeadline: Date
  ) {
    self.trialId = trialId
    self.epoch = epoch
    self.generation = generation
    self.state = state
    self.candidateDigest = candidateDigest
    self.baseDigest = baseDigest
    self.baseRevision = baseRevision
    self.replacementDigest = replacementDigest
    self.counts = counts
    self.assignmentDeadline = assignmentDeadline
    self.decisionDeadline = decisionDeadline
  }
}

public struct AdmissionDecisionInputs: Sendable, Equatable, Codable {
  public let candidateDigest: CandidateDigest

  public init(candidateDigest: CandidateDigest) {
    self.candidateDigest = candidateDigest
  }

  enum CodingKeys: String, CodingKey {
    case candidateDigest = "candidate_digest"
  }
}

public struct ReflectionNoCandidateInputs: Sendable, Equatable, Codable {
  public let triggerDigest: TriggerDigest
  public let operationId: LearningOperationID
  public let carrierDigest: CarrierDigest

  public init(
    triggerDigest: TriggerDigest,
    operationId: LearningOperationID,
    carrierDigest: CarrierDigest
  ) {
    self.triggerDigest = triggerDigest
    self.operationId = operationId
    self.carrierDigest = carrierDigest
  }

  enum CodingKeys: String, CodingKey {
    case triggerDigest = "trigger_digest"
    case operationId = "operation_id"
    case carrierDigest = "carrier_digest"
  }
}

public struct ReflectionNoCandidateReceipt: Sendable, Equatable, Codable {
  public static let kind = "reflection_no_candidate"

  public let resultDigest: ReflectionResultDigest

  public init(resultDigest: ReflectionResultDigest) {
    self.resultDigest = resultDigest
  }

  enum CodingKeys: String, CodingKey {
    case resultDigest = "result_digest"
  }
}

/// The immutable decision receipt shapes production can currently write.
public enum LearningDecisionDetail: Sendable, Equatable {
  case candidateAdmission(inputs: AdmissionDecisionInputs, result: AdmissionReceipt)
  case reflectionNoCandidate(
    inputs: ReflectionNoCandidateInputs,
    result: ReflectionNoCandidateReceipt
  )
  case learningReset(
    inputs: LearningResetDecisionInputs,
    result: LearningResetDecisionResult
  )
}

public struct LearningDecisionView: Sendable, Equatable {
  public let decisionId: Int64
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let algorithm: LearningAlgorithm
  public let decidedAt: Date
  public let detail: LearningDecisionDetail

  public init(
    decisionId: Int64,
    jobId: Int64,
    epoch: LearningEpoch,
    algorithm: LearningAlgorithm,
    decidedAt: Date,
    detail: LearningDecisionDetail
  ) {
    self.decisionId = decisionId
    self.jobId = jobId
    self.epoch = epoch
    self.algorithm = algorithm
    self.decidedAt = decidedAt
    self.detail = detail
  }
}

public struct ReadableJobLearningView: Sendable, Equatable {
  public let job: LearningJobIdentity
  public let epoch: LearningEpoch
  public let stableRevision: StableRevision
  public let stableLessons: LessonSet
  public let liveTrial: LearningTrialView?
  public let lastDecision: LearningDecisionView?
  public let warnings: [LearningViewWarning]

  public init(
    job: LearningJobIdentity,
    epoch: LearningEpoch,
    stableRevision: StableRevision,
    stableLessons: LessonSet,
    liveTrial: LearningTrialView?,
    lastDecision: LearningDecisionView?,
    warnings: [LearningViewWarning]
  ) {
    self.job = job
    self.epoch = epoch
    self.stableRevision = stableRevision
    self.stableLessons = stableLessons
    self.liveTrial = liveTrial
    self.lastDecision = lastDecision
    self.warnings = warnings
  }
}

/// One list/detail query result. A detail request always returns exactly one case; a list returns
/// readable or unreadable armed jobs only and uses an empty array for no learning state.
public enum JobLearningView: Sendable, Equatable {
  case readable(ReadableJobLearningView)
  case unarmed(LearningJobIdentity)
  case notFound(jobId: Int64)
  case unreadable(UnreadableLearningJob)
}
