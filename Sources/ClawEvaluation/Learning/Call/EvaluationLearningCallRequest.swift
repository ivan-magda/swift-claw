import ClawCore
import Foundation

package struct EvaluationLearningCallRequest: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let executionProfile: EvaluationLearningExecutionProfile
  package let jobID: String
  package let operationID: String
  package let attemptGeneration: Int
  package let providerCallID: ProviderCallID
  package let kind: EvaluationLearningOperationKind
  package let stateRoot: String
  package let prompt: EvaluationLearningArtifactBinding
  package let carrier: EvaluationLearningArtifactBinding
  package let resultPath: String
  package let manifest: EvaluationLearningManifestBinding
  package let authorization: EvaluationLearningOperationAuthorization

  package init(
    schemaVersion: Int = 1,
    executionProfile: EvaluationLearningExecutionProfile,
    jobID: String,
    operationID: String,
    attemptGeneration: Int,
    providerCallID: ProviderCallID,
    kind: EvaluationLearningOperationKind,
    stateRoot: String,
    prompt: EvaluationLearningArtifactBinding,
    carrier: EvaluationLearningArtifactBinding,
    resultPath: String,
    manifest: EvaluationLearningManifestBinding,
    authorization: EvaluationLearningOperationAuthorization
  ) {
    self.schemaVersion = schemaVersion
    self.executionProfile = executionProfile
    self.jobID = jobID
    self.operationID = operationID
    self.attemptGeneration = attemptGeneration
    self.providerCallID = providerCallID
    self.kind = kind
    self.stateRoot = stateRoot
    self.prompt = prompt
    self.carrier = carrier
    self.resultPath = resultPath
    self.manifest = manifest
    self.authorization = authorization
  }

  package var core: EvaluationLearningCallRequestCore {
    EvaluationLearningCallRequestCore(
      schemaVersion: schemaVersion,
      executionProfile: executionProfile,
      jobID: jobID,
      operationID: operationID,
      attemptGeneration: attemptGeneration,
      providerCallID: providerCallID,
      kind: kind,
      stateRoot: stateRoot,
      prompt: prompt,
      carrier: carrier,
      resultPath: resultPath,
      manifest: manifest
    )
  }

  package static func load(from url: URL) throws -> Self {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    let object = try EvaluationLearningClosedJSON.object(from: data)
    try EvaluationLearningAdmissionVerifier.requireExactKeys(
      object,
      keys: Set(CodingKeys.allCases.map(\.rawValue))
    )
    try EvaluationLearningAdmissionVerifier.requireExactObjectKeys(
      in: object,
      path: [CodingKeys.prompt.rawValue],
      keys: ["path", "sha256"]
    )
    try EvaluationLearningAdmissionVerifier.requireExactObjectKeys(
      in: object,
      path: [CodingKeys.carrier.rawValue],
      keys: ["path", "sha256"]
    )
    try EvaluationLearningAdmissionVerifier.requireExactObjectKeys(
      in: object,
      path: [CodingKeys.manifest.rawValue],
      keys: [
        "repository_root", "evaluation_root", "manifest_path", "manifest_sha256",
        "owner_approval",
      ]
    )
    try EvaluationLearningAdmissionVerifier.requireExactObjectKeys(
      in: object,
      path: [CodingKeys.manifest.rawValue, "owner_approval"],
      keys: ["path", "sha256"]
    )
    try EvaluationLearningAdmissionVerifier.requireExactObjectKeys(
      in: object,
      path: [CodingKeys.authorization.rawValue],
      keys: ["event_path", "event_sha256"]
    )
    let request = try EvaluationLearningClosedJSON.decode(
      Self.self,
      from: data,
      object: object
    )
    try request.validate()
    return request
  }

  package func validate() throws {
    guard
      schemaVersion == 1,
      executionProfile == .scheduledLearningV1,
      kind == .evaluator || kind == .reflector,
      jobID.isEmpty == false,
      operationID.isEmpty == false,
      attemptGeneration > 0,
      EvaluationLearningAdmissionVerifier.isCanonicalProviderCallID(providerCallID),
      SHA256Digest.isCanonicalHex(prompt.sha256),
      SHA256Digest.isCanonicalHex(carrier.sha256),
      SHA256Digest.isCanonicalHex(manifest.manifestSHA256),
      SHA256Digest.isCanonicalHex(manifest.ownerApproval.sha256),
      SHA256Digest.isCanonicalHex(authorization.eventSHA256)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }

    let repository = try EvaluationLearningAdmissionVerifier.absoluteURL(manifest.repositoryRoot)
    let evaluation = try EvaluationLearningAdmissionVerifier.absoluteURL(manifest.evaluationRoot)
    let state = try EvaluationLearningAdmissionVerifier.absoluteURL(stateRoot)
    let promptURL = try EvaluationLearningAdmissionVerifier.absoluteURL(prompt.path)
    let carrierURL = try EvaluationLearningAdmissionVerifier.absoluteURL(carrier.path)
    let resultURL = try EvaluationLearningAdmissionVerifier.absoluteURL(resultPath)
    let manifestURL = try EvaluationLearningAdmissionVerifier.absoluteURL(manifest.manifestPath)
    let approvalURL = try EvaluationLearningAdmissionVerifier.absoluteURL(
      manifest.ownerApproval.path
    )
    let eventURL = try EvaluationLearningAdmissionVerifier.absoluteURL(authorization.eventPath)
    guard
      EvaluationPathSecurity.isStrictlyContained(evaluation, under: repository),
      EvaluationPathSecurity.isStrictlyContained(state, under: evaluation),
      EvaluationPathSecurity.isStrictlyContained(promptURL, under: repository),
      EvaluationPathSecurity.isStrictlyContained(carrierURL, under: evaluation),
      EvaluationPathSecurity.isStrictlyContained(resultURL, under: state),
      EvaluationPathSecurity.isStrictlyContained(manifestURL, under: repository),
      EvaluationPathSecurity.isStrictlyContained(approvalURL, under: repository),
      EvaluationPathSecurity.isStrictlyContained(eventURL, under: evaluation)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [
        repository, evaluation, state, promptURL, carrierURL, resultURL, manifestURL, approvalURL,
        eventURL,
      ]
    )
  }

  package enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case executionProfile = "execution_profile"
    case jobID = "job_id"
    case operationID = "operation_id"
    case attemptGeneration = "attempt_generation"
    case providerCallID = "provider_call_id"
    case kind
    case stateRoot = "state_root"
    case prompt
    case carrier
    case resultPath = "result_path"
    case manifest
    case authorization
  }
}

package struct EvaluationLearningCallRequestCore: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let executionProfile: EvaluationLearningExecutionProfile
  package let jobID: String
  package let operationID: String
  package let attemptGeneration: Int
  package let providerCallID: ProviderCallID
  package let kind: EvaluationLearningOperationKind
  package let stateRoot: String
  package let prompt: EvaluationLearningArtifactBinding
  package let carrier: EvaluationLearningArtifactBinding
  package let resultPath: String
  package let manifest: EvaluationLearningManifestBinding

  package var sha256: String {
    guard let data = try? EvaluationCanonicalJSON.data(encoding: self) else {
      return ""
    }
    return SHA256Digest.hex(data)
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case executionProfile = "execution_profile"
    case jobID = "job_id"
    case operationID = "operation_id"
    case attemptGeneration = "attempt_generation"
    case providerCallID = "provider_call_id"
    case kind
    case stateRoot = "state_root"
    case prompt
    case carrier
    case resultPath = "result_path"
    case manifest
  }
}
