import Foundation

enum EvaluationWorkspaceFailureReason:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable,
  CaseIterable
{
  case sourceArtifactInsideWorkspace = "source_artifact_inside_workspace"
  case lessonArtifactInsideWorkspace = "lesson_artifact_inside_workspace"
  case sourceDigestMismatch = "source_digest_mismatch"
  case invalidSourceArtifact = "invalid_source_artifact"
  case invalidSynthesisInput = "invalid_synthesis_input"
  case missingLessonArtifact = "missing_lesson_artifact"
  case lessonDigestMismatch = "lesson_digest_mismatch"
  case invalidLessonArtifact = "invalid_lesson_artifact"
  case invalidActiveLessonPointer = "invalid_active_lesson_pointer"
  case activeLessonDigestMismatch = "active_lesson_digest_mismatch"
  case activeLessonIdentityMismatch = "active_lesson_identity_mismatch"
  case immutableLessonCollision = "immutable_lesson_collision"
  case inputDigestMismatch = "input_digest_mismatch"
  case inputIsNotUTF8 = "input_not_utf8"
  case inputGraphemeLimitExceeded = "input_grapheme_limit"
  case unexpectedWorkspaceContents = "unexpected_workspace_contents"
  case policyMismatch = "policy_mismatch"

  var classification: EvaluationPageTerminalClassification {
    switch self {
    case .lessonDigestMismatch, .invalidActiveLessonPointer, .activeLessonDigestMismatch,
      .activeLessonIdentityMismatch, .inputDigestMismatch, .policyMismatch:
      .carrierFailure
    default:
      .invalidBatch
    }
  }
}

/// A pre-inference worker can fail before an `EvaluationAttemptResult` exists. This closed sidecar
/// preserves the authenticated invocation/configuration identity across the process boundary so a
/// controller never infers carrier semantics from an arbitrary nonzero exit.
struct EvaluationWorkerFailureEvidence: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let invocationID: UUID
  let configurationSHA256: String
  let attemptID: String
  let manifestSHA256: String
  let classification: EvaluationPageTerminalClassification
  let reason: EvaluationWorkspaceFailureReason

  init(
    schemaVersion: Int,
    invocationID: UUID,
    configurationSHA256: String,
    attemptID: String,
    manifestSHA256: String,
    classification: EvaluationPageTerminalClassification,
    reason: EvaluationWorkspaceFailureReason
  ) {
    self.schemaVersion = schemaVersion
    self.invocationID = invocationID
    self.configurationSHA256 = configurationSHA256
    self.attemptID = attemptID
    self.manifestSHA256 = manifestSHA256
    self.classification = classification
    self.reason = reason
  }

  init(
    error: EvaluationWorkspaceError,
    invocation: EvaluationWorkerInvocation,
    configuration: EvaluationAttemptConfiguration
  ) {
    self.init(
      reason: error.failureReason,
      invocation: invocation,
      configuration: configuration
    )
  }

  init(
    reason: EvaluationWorkspaceFailureReason,
    invocation: EvaluationWorkerInvocation,
    configuration: EvaluationAttemptConfiguration
  ) {
    self.init(
      schemaVersion: PageEvaluationContract.schemaVersion,
      invocationID: invocation.invocationID,
      configurationSHA256: invocation.configurationSHA256,
      attemptID: configuration.attemptID,
      manifestSHA256: configuration.approval.manifestSHA256,
      classification: reason.classification,
      reason: reason
    )
  }

  func validate(
    invocationID: UUID,
    configurationSHA256: String,
    configuration: EvaluationAttemptConfiguration
  ) throws {
    guard
      schemaVersion == PageEvaluationContract.schemaVersion,
      self.invocationID == invocationID,
      self.configurationSHA256 == configurationSHA256,
      attemptID == configuration.attemptID,
      manifestSHA256 == configuration.approval.manifestSHA256,
      classification == reason.classification
    else { throw EvaluationPagePipelineError.invalidBatch("worker_failure_evidence_identity") }
  }

  static func url(for resultURL: URL) -> URL {
    resultURL.appendingPathExtension("worker-failure.json")
  }

  static func publish(
    _ error: EvaluationWorkspaceError,
    invocation: EvaluationWorkerInvocation,
    configuration: EvaluationAttemptConfiguration
  ) throws {
    try EvaluationJSONFile.write(
      Self(error: error, invocation: invocation, configuration: configuration),
      to: url(for: configuration.resultURL)
    )
  }

  static func publishIfClassified(
    _ error: EvaluationAttemptError,
    invocation: EvaluationWorkerInvocation,
    configuration: EvaluationAttemptConfiguration
  ) throws {
    guard case .policyMismatch = error else { return }
    try EvaluationJSONFile.write(
      Self(reason: .policyMismatch, invocation: invocation, configuration: configuration),
      to: url(for: configuration.resultURL)
    )
  }

  static func loadIfPresent(
    invocationID: UUID,
    configurationSHA256: String,
    configuration: EvaluationAttemptConfiguration
  ) throws -> Self? {
    let url = url(for: configuration.resultURL)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let evidence = try EvaluationJSONFile.decode(Self.self, from: url)
    try evidence.validate(
      invocationID: invocationID,
      configurationSHA256: configurationSHA256,
      configuration: configuration
    )
    return evidence
  }

  static func terminalErrorIfPresent(
    invocationID: UUID,
    configurationSHA256: String,
    configurations: [EvaluationAttemptConfiguration]
  ) throws -> EvaluationPagePipelineError? {
    let evidence: [Self]
    do {
      evidence = try configurations.compactMap {
        try loadIfPresent(
          invocationID: invocationID,
          configurationSHA256: configurationSHA256,
          configuration: $0
        )
      }
    } catch {
      throw EvaluationPagePipelineError.invalidBatch("worker_failure_evidence_invalid")
    }
    guard evidence.count <= 1 else {
      throw EvaluationPagePipelineError.invalidBatch("worker_failure_evidence_ambiguous")
    }
    guard let terminal = evidence.first else { return nil }
    switch terminal.classification {
    case .carrierFailure:
      return .carrierFailure(terminal.reason.rawValue)
    case .invalidBatch:
      return .invalidBatch(terminal.reason.rawValue)
    case .safetyFailure, .pageTaskSpecificFailure, .incompleteBatch:
      throw EvaluationPagePipelineError.invalidBatch("worker_failure_evidence_classification")
    }
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case invocationID = "invocation_id"
    case configurationSHA256 = "configuration_sha256"
    case attemptID = "attempt_id"
    case manifestSHA256 = "manifest_sha256"
    case classification, reason
  }
}

extension EvaluationWorkspaceError {
  var failureReason: EvaluationWorkspaceFailureReason {
    switch self {
    case .sourceArtifactInsideWorkspace: .sourceArtifactInsideWorkspace
    case .lessonArtifactInsideWorkspace: .lessonArtifactInsideWorkspace
    case .sourceDigestMismatch: .sourceDigestMismatch
    case .invalidSourceArtifact: .invalidSourceArtifact
    case .invalidSynthesisInput: .invalidSynthesisInput
    case .missingLessonArtifact: .missingLessonArtifact
    case .lessonDigestMismatch: .lessonDigestMismatch
    case .invalidLessonArtifact: .invalidLessonArtifact
    case .invalidActiveLessonPointer: .invalidActiveLessonPointer
    case .activeLessonDigestMismatch: .activeLessonDigestMismatch
    case .activeLessonIdentityMismatch: .activeLessonIdentityMismatch
    case .immutableLessonCollision: .immutableLessonCollision
    case .inputDigestMismatch: .inputDigestMismatch
    case .inputIsNotUTF8: .inputIsNotUTF8
    case .inputGraphemeLimitExceeded: .inputGraphemeLimitExceeded
    case .unexpectedWorkspaceContents: .unexpectedWorkspaceContents
    }
  }
}
