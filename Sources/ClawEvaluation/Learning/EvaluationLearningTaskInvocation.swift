import ClawCore
import Foundation

package struct EvaluationLearningTaskInvocation: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let executionProfile: EvaluationLearningExecutionProfile
  package let jobID: String
  package let operationID: String
  package let attemptGeneration: Int
  package let providerCallID: ProviderCallID
  package let configurationPath: String
  package let configurationSHA256: String
  package let manifest: EvaluationLearningManifestBinding
  package let budget: EvaluationSendBudgetSnapshot
  package let authorization: EvaluationLearningOperationAuthorization

  package init(
    schemaVersion: Int = 1,
    executionProfile: EvaluationLearningExecutionProfile,
    jobID: String,
    operationID: String,
    attemptGeneration: Int,
    providerCallID: ProviderCallID,
    configurationPath: String,
    configurationSHA256: String,
    manifest: EvaluationLearningManifestBinding,
    budget: EvaluationSendBudgetSnapshot,
    authorization: EvaluationLearningOperationAuthorization
  ) {
    self.schemaVersion = schemaVersion
    self.executionProfile = executionProfile
    self.jobID = jobID
    self.operationID = operationID
    self.attemptGeneration = attemptGeneration
    self.providerCallID = providerCallID
    self.configurationPath = configurationPath
    self.configurationSHA256 = configurationSHA256
    self.manifest = manifest
    self.budget = budget
    self.authorization = authorization
  }

  package var core: EvaluationLearningTaskInvocationCore {
    EvaluationLearningTaskInvocationCore(
      schemaVersion: schemaVersion,
      executionProfile: executionProfile,
      jobID: jobID,
      operationID: operationID,
      attemptGeneration: attemptGeneration,
      providerCallID: providerCallID,
      configurationPath: configurationPath,
      configurationSHA256: configurationSHA256,
      manifest: manifest,
      budget: budget
    )
  }

  package func validate() throws {
    guard
      schemaVersion == 1,
      executionProfile == .scheduledLearningV1,
      jobID.isEmpty == false,
      operationID.isEmpty == false,
      attemptGeneration > 0,
      Self.isCanonical(providerCallID),
      SHA256Digest.isCanonicalHex(configurationSHA256),
      SHA256Digest.isCanonicalHex(manifest.manifestSHA256),
      SHA256Digest.isCanonicalHex(manifest.ownerApproval.sha256),
      SHA256Digest.isCanonicalHex(authorization.eventSHA256)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    let repository = try Self.absoluteURL(manifest.repositoryRoot)
    let evaluation = try Self.absoluteURL(manifest.evaluationRoot)
    let configuration = try Self.absoluteURL(configurationPath)
    let manifestURL = try Self.absoluteURL(manifest.manifestPath)
    let approval = try Self.absoluteURL(manifest.ownerApproval.path)
    let event = try Self.absoluteURL(authorization.eventPath)
    guard
      EvaluationPathSecurity.isStrictlyContained(evaluation, under: repository),
      EvaluationPathSecurity.isStrictlyContained(configuration, under: repository),
      EvaluationPathSecurity.isStrictlyContained(manifestURL, under: repository),
      EvaluationPathSecurity.isStrictlyContained(approval, under: repository),
      EvaluationPathSecurity.isStrictlyContained(event, under: evaluation)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [repository, evaluation, configuration, manifestURL, approval, event]
    )
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case executionProfile = "execution_profile"
    case jobID = "job_id"
    case operationID = "operation_id"
    case attemptGeneration = "attempt_generation"
    case providerCallID = "provider_call_id"
    case configurationPath = "configuration_path"
    case configurationSHA256 = "configuration_sha256"
    case manifest
    case budget
    case authorization
  }
}

package struct EvaluationLearningTaskInvocationCore: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let executionProfile: EvaluationLearningExecutionProfile
  package let jobID: String
  package let operationID: String
  package let attemptGeneration: Int
  package let providerCallID: ProviderCallID
  package let configurationPath: String
  package let configurationSHA256: String
  package let manifest: EvaluationLearningManifestBinding
  package let budget: EvaluationSendBudgetSnapshot

  package init(
    schemaVersion: Int = 1,
    executionProfile: EvaluationLearningExecutionProfile,
    jobID: String,
    operationID: String,
    attemptGeneration: Int,
    providerCallID: ProviderCallID,
    configurationPath: String,
    configurationSHA256: String,
    manifest: EvaluationLearningManifestBinding,
    budget: EvaluationSendBudgetSnapshot
  ) {
    self.schemaVersion = schemaVersion
    self.executionProfile = executionProfile
    self.jobID = jobID
    self.operationID = operationID
    self.attemptGeneration = attemptGeneration
    self.providerCallID = providerCallID
    self.configurationPath = configurationPath
    self.configurationSHA256 = configurationSHA256
    self.manifest = manifest
    self.budget = budget
  }

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
    case configurationPath = "configuration_path"
    case configurationSHA256 = "configuration_sha256"
    case manifest
    case budget
  }
}

package enum EvaluationWorkerInput: Sendable {
  case legacy(EvaluationWorkerInvocation)
  case scheduledLearning(EvaluationLearningTaskInvocation)

  package static func decode(from url: URL) throws -> Self {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw EvaluationWorkerInputError.invalidInput
    }
    guard let rawProfile = object["execution_profile"] else {
      return .legacy(try JSONDecoder().decode(EvaluationWorkerInvocation.self, from: data))
    }
    guard
      let profile = rawProfile as? String,
      profile == EvaluationLearningExecutionProfile.scheduledLearningV1.rawValue
    else {
      throw EvaluationWorkerInputError.unknownExecutionProfile
    }
    let invocation = try EvaluationLearningClosedJSON.decode(
      EvaluationLearningTaskInvocation.self,
      from: data,
      requiredKeys: Set(EvaluationLearningTaskInvocation.CodingKeys.allCases.map(\.rawValue))
    )
    return .scheduledLearning(invocation)
  }
}

package enum EvaluationWorkerInputError: Error, Sendable, Equatable {
  case invalidInput
  case unknownExecutionProfile
}

package final class EvaluationLearningProviderCallIDGenerator:
  ProviderCallIDGenerating, @unchecked Sendable
{
  private let lock = NSLock()
  private var storedFirst: ProviderCallID?
  private let subsequent = UUIDProviderCallIDGenerator()

  package init(first: ProviderCallID) {
    storedFirst = first
  }

  package func next() -> ProviderCallID {
    lock.lock()
    defer { lock.unlock() }
    if let storedFirst {
      self.storedFirst = nil
      return storedFirst
    }
    return subsequent.next()
  }
}

private extension EvaluationLearningTaskInvocation {
  static func absoluteURL(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path)
    guard path.hasPrefix("/"), url.standardizedFileURL.path == path else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    return url
  }

  static func isCanonical(_ providerCallID: ProviderCallID) -> Bool {
    guard let identifier = UUID(uuidString: providerCallID.rawValue) else {
      return false
    }
    return identifier.uuidString.lowercased() == providerCallID.rawValue
  }
}
