import Foundation

public enum CandidateOrigin: String, Sendable, Equatable, Codable {
  case reflection
  case ownerEdit = "owner_edit"
  case ownerApproval = "owner_approval"
}

public struct CandidateEvidenceSource: Sendable, Equatable, Codable {
  public let runId: Int64
  public let digest: EvidenceDigest
  public let evaluationDigest: EvaluationDigest
  public let evaluationRequired: Bool

  public init(
    runId: Int64,
    digest: EvidenceDigest,
    evaluationDigest: EvaluationDigest,
    evaluationRequired: Bool
  ) {
    self.runId = runId
    self.digest = digest
    self.evaluationDigest = evaluationDigest
    self.evaluationRequired = evaluationRequired
  }

  enum CodingKeys: String, CodingKey {
    case runId = "run_id"
    case digest = "evidence_digest"
    case evaluationDigest = "evaluation_digest"
    case evaluationRequired = "evaluation_required"
  }
}

public struct CandidateEvaluationSource: Sendable, Equatable, Codable {
  public let runId: Int64
  public let digest: EvaluationDigest

  public init(runId: Int64, digest: EvaluationDigest) {
    self.runId = runId
    self.digest = digest
  }

  enum CodingKeys: String, CodingKey {
    case runId = "run_id"
    case digest = "evaluation_digest"
  }
}

public struct CandidateFeedbackSource: Sendable, Equatable, Codable {
  public let eventId: Int64
  public let digest: FeedbackEventDigest
  public let revision: FeedbackRevision
  public let subjectKind: FeedbackSubjectKind
  public let subjectDigest: String
  public let signal: OwnerSignal

  public init(
    eventId: Int64,
    digest: FeedbackEventDigest,
    revision: FeedbackRevision,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String,
    signal: OwnerSignal
  ) {
    self.eventId = eventId
    self.digest = digest
    self.revision = revision
    self.subjectKind = subjectKind
    self.subjectDigest = subjectDigest
    self.signal = signal
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawKind = try container.decode(String.self, forKey: .subjectKind)
    let rawSignal = try container.decode(String.self, forKey: .signal)
    guard
      let subjectKind = FeedbackSubjectKind(rawValue: rawKind),
      let signal = OwnerSignal(rawValue: rawSignal),
      signal.feedbackSubjectKind == subjectKind
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .signal,
        in: container,
        debugDescription: "feedback source carries an invalid subject or signal"
      )
    }
    eventId = try container.decode(Int64.self, forKey: .eventId)
    digest = try container.decode(FeedbackEventDigest.self, forKey: .digest)
    revision = FeedbackRevision(try container.decode(Int64.self, forKey: .revision))
    self.subjectKind = subjectKind
    subjectDigest = try container.decode(String.self, forKey: .subjectDigest)
    self.signal = signal
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(eventId, forKey: .eventId)
    try container.encode(digest, forKey: .digest)
    try container.encode(revision.value, forKey: .revision)
    try container.encode(subjectKind.rawValue, forKey: .subjectKind)
    try container.encode(subjectDigest, forKey: .subjectDigest)
    try container.encode(signal.rawValue, forKey: .signal)
  }

  enum CodingKeys: String, CodingKey {
    case eventId = "event_id"
    case digest = "event_digest"
    case revision = "feedback_revision"
    case subjectKind = "subject_kind"
    case subjectDigest = "subject_digest"
    case signal
  }
}

/// The immutable transitive provenance of one proposed replacement. The manifest contains no
/// candidate digest, so candidate identity can hash it without becoming self-referential.
public struct CandidateSourceManifest: Sendable, Equatable, Codable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let origin: CandidateOrigin
  public let algorithm: LearningAlgorithm
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let triggerDigest: TriggerDigest
  public let triggerReason: LearningTriggerReason
  public let qualifyingIssueCodes: [String]
  public let operationId: LearningOperationID
  public let carrierDigest: CarrierDigest
  public let resultDigest: ReflectionResultDigest
  public let baseDigest: LessonSetDigest
  public let baseRevision: StableRevision
  public let feedbackRevision: FeedbackRevision
  public let evidence: [CandidateEvidenceSource]
  public let evaluations: [CandidateEvaluationSource]
  public let feedback: [CandidateFeedbackSource]
  public let predecessorCandidate: CandidateDigest?
  public let predecessorFeedback: CandidateFeedbackSource?

  public init(  // swiftlint:disable:this function_parameter_count
    schemaVersion: Int = CandidateSourceManifest.currentSchemaVersion,
    origin: CandidateOrigin,
    algorithm: LearningAlgorithm,
    jobId: Int64,
    epoch: LearningEpoch,
    triggerDigest: TriggerDigest,
    triggerReason: LearningTriggerReason,
    qualifyingIssueCodes: [String],
    operationId: LearningOperationID,
    carrierDigest: CarrierDigest,
    resultDigest: ReflectionResultDigest,
    baseDigest: LessonSetDigest,
    baseRevision: StableRevision,
    feedbackRevision: FeedbackRevision,
    evidence: [CandidateEvidenceSource],
    evaluations: [CandidateEvaluationSource],
    feedback: [CandidateFeedbackSource],
    predecessorCandidate: CandidateDigest?,
    predecessorFeedback: CandidateFeedbackSource?
  ) {
    self.schemaVersion = schemaVersion
    self.origin = origin
    self.algorithm = algorithm
    self.jobId = jobId
    self.epoch = epoch
    self.triggerDigest = triggerDigest
    self.triggerReason = triggerReason
    self.qualifyingIssueCodes = qualifyingIssueCodes
    self.operationId = operationId
    self.carrierDigest = carrierDigest
    self.resultDigest = resultDigest
    self.baseDigest = baseDigest
    self.baseRevision = baseRevision
    self.feedbackRevision = feedbackRevision
    self.evidence = evidence
    self.evaluations = evaluations
    self.feedback = feedback
    self.predecessorCandidate = predecessorCandidate
    self.predecessorFeedback = predecessorFeedback
  }

  public var digest: CandidateSourceManifestDigest {
    get throws {
      let bytes = try CanonicalJSON.data(encoding: self)
      let framed = CanonicalDigestInput.joined([
        Self.digestDomain, bytes.base64EncodedString(),
      ])
      return CandidateSourceManifestDigest(rawValue: SHA256Digest.hex(framed))
    }
  }

  private static let digestDomain = "candidate-source-manifest/v1"

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case origin
    case algorithm
    case jobId = "job_id"
    case epoch = "learning_epoch"
    case triggerDigest = "trigger_digest"
    case triggerReason = "trigger_reason"
    case qualifyingIssueCodes = "qualifying_issue_codes"
    case operationId = "operation_id"
    case carrierDigest = "carrier_digest"
    case resultDigest = "result_digest"
    case baseDigest = "base_digest"
    case baseRevision = "base_revision"
    case feedbackRevision = "feedback_revision"
    case evidence
    case evaluations
    case feedback
    case predecessorCandidate = "predecessor_candidate"
    case predecessorFeedback = "predecessor_feedback"
  }
}

/// A validated replacement plus its immutable provenance. Both digests are always derived here;
/// no caller supplies either one alongside bytes that could disagree with it.
public struct CandidateArtifact: Sendable, Equatable {
  public let replacement: LessonSet
  public let digest: CandidateDigest
  public let manifest: CandidateSourceManifest

  public init(replacement: LessonSet, manifest: CandidateSourceManifest) throws {
    self.replacement = replacement
    self.manifest = manifest
    let fields = [
      Self.digestDomain,
      manifest.origin.rawValue,
      replacement.digest.rawValue,
      try manifest.digest.rawValue,
    ]
    digest = CandidateDigest(rawValue: SHA256Digest.hex(CanonicalDigestInput.joined(fields)))
  }

  private static let digestDomain = "learning-candidate/v1"
}

/// The frozen source rows a reflector carrier was assembled from. It has no operation or result
/// identity yet; those join only after the claim and the exact reply exist.
public struct ReflectionPreparation: Sendable, Equatable {
  public let trigger: TriggerIdentity
  public let stableLessons: LessonSet
  public let stableRevision: StableRevision
  public let evaluations: [PreparedReflectionEvaluation]
  public let feedbackSources: [CandidateFeedbackSource]
  public let ownerPayloads: [PreparedOwnerPayload]

  public init(
    trigger: TriggerIdentity,
    stableLessons: LessonSet,
    stableRevision: StableRevision,
    evaluations: [PreparedReflectionEvaluation],
    feedbackSources: [CandidateFeedbackSource],
    ownerPayloads: [PreparedOwnerPayload]
  ) {
    self.trigger = trigger
    self.stableLessons = stableLessons
    self.stableRevision = stableRevision
    self.evaluations = evaluations
    self.feedbackSources = feedbackSources
    self.ownerPayloads = ownerPayloads
  }

  public var evidenceSources: [CandidateEvidenceSource] {
    evaluations.map(\.evidence)
  }

  public var evaluationSources: [CandidateEvaluationSource] {
    evaluations.map(\.evaluation)
  }
}

public struct PreparedReflectionEvaluation: Sendable, Equatable {
  public let evidence: CandidateEvidenceSource
  public let evaluation: CandidateEvaluationSource
  public let summary: ReflectorEvaluationSummary

  public init(
    evidence: CandidateEvidenceSource,
    evaluation: CandidateEvaluationSource,
    summary: ReflectorEvaluationSummary
  ) {
    self.evidence = evidence
    self.evaluation = evaluation
    self.summary = summary
  }
}

public struct PreparedOwnerPayload: Sendable, Equatable {
  public let source: CandidateFeedbackSource
  public let payload: String

  public init(source: CandidateFeedbackSource, payload: String) {
    self.source = source
    self.payload = payload
  }
}
