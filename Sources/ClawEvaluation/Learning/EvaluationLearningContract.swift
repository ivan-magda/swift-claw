import ClawCore
import Foundation

package enum EvaluationLearningExecutionProfile: String, Codable, Sendable {
  case scheduledLearningV1 = "scheduled-learning-v1"
}

package enum EvaluationLearningOperationKind: String, Codable, Sendable {
  case task
  case evaluator
  case reflector
}

package struct EvaluationLearningRouteBinding: Codable, Sendable, Equatable {
  package let providerReference: String
  package let wireModel: String
  package let retryBudget: Int
  package let maxOutputTokens: Int
  package let maxOutputUTF8Bytes: Int
  package let maxOutputGraphemes: Int

  package init(
    providerReference: String,
    wireModel: String,
    retryBudget: Int,
    maxOutputTokens: Int,
    maxOutputUTF8Bytes: Int,
    maxOutputGraphemes: Int
  ) {
    self.providerReference = providerReference
    self.wireModel = wireModel
    self.retryBudget = retryBudget
    self.maxOutputTokens = maxOutputTokens
    self.maxOutputUTF8Bytes = maxOutputUTF8Bytes
    self.maxOutputGraphemes = maxOutputGraphemes
  }

  enum CodingKeys: String, CodingKey {
    case providerReference = "provider_reference"
    case wireModel = "wire_model"
    case retryBudget = "retry_budget"
    case maxOutputTokens = "max_output_tokens"
    case maxOutputUTF8Bytes = "max_output_utf8_bytes"
    case maxOutputGraphemes = "max_output_graphemes"
  }
}

package struct EvaluationLearningArtifactBinding: Codable, Sendable, Equatable {
  package let path: String
  package let sha256: String

  package init(path: String, sha256: String) {
    self.path = path
    self.sha256 = sha256
  }

  enum CodingKeys: String, CodingKey {
    case path
    case sha256
  }
}

package struct EvaluationLearningManifestBinding: Codable, Sendable, Equatable {
  package let repositoryRoot: String
  package let evaluationRoot: String
  package let manifestPath: String
  package let manifestSHA256: String
  package let ownerApproval: EvaluationLearningArtifactBinding

  package init(
    repositoryRoot: String,
    evaluationRoot: String,
    manifestPath: String,
    manifestSHA256: String,
    ownerApproval: EvaluationLearningArtifactBinding
  ) {
    self.repositoryRoot = repositoryRoot
    self.evaluationRoot = evaluationRoot
    self.manifestPath = manifestPath
    self.manifestSHA256 = manifestSHA256
    self.ownerApproval = ownerApproval
  }

  enum CodingKeys: String, CodingKey {
    case repositoryRoot = "repository_root"
    case evaluationRoot = "evaluation_root"
    case manifestPath = "manifest_path"
    case manifestSHA256 = "manifest_sha256"
    case ownerApproval = "owner_approval"
  }
}

package struct EvaluationLearningManifestProjection: Sendable, Equatable {
  package let executableSHA256: String
  package let missingUsageTokenProxy: Int
  package let budgets: EvaluationLearningApprovedBudgets
  package let taskRoute: EvaluationLearningRouteBinding
  package let evaluatorRoute: EvaluationLearningRouteBinding
  package let reflectorRoute: EvaluationLearningRouteBinding

  package init(
    executableSHA256: String,
    missingUsageTokenProxy: Int,
    budgets: EvaluationLearningApprovedBudgets,
    taskRoute: EvaluationLearningRouteBinding,
    evaluatorRoute: EvaluationLearningRouteBinding,
    reflectorRoute: EvaluationLearningRouteBinding
  ) {
    self.executableSHA256 = executableSHA256
    self.missingUsageTokenProxy = missingUsageTokenProxy
    self.budgets = budgets
    self.taskRoute = taskRoute
    self.evaluatorRoute = evaluatorRoute
    self.reflectorRoute = reflectorRoute
  }
}

package struct EvaluationLearningApprovedBudgets: Codable, Sendable, Equatable {
  package let taskAttempts: Int
  package let evaluatorCalls: Int
  package let reflectorCalls: Int
  package let responsesSends: Int
  package let accountedTokens: Int

  package init(
    taskAttempts: Int,
    evaluatorCalls: Int,
    reflectorCalls: Int,
    responsesSends: Int,
    accountedTokens: Int
  ) {
    self.taskAttempts = taskAttempts
    self.evaluatorCalls = evaluatorCalls
    self.reflectorCalls = reflectorCalls
    self.responsesSends = responsesSends
    self.accountedTokens = accountedTokens
  }

  enum CodingKeys: String, CodingKey {
    case taskAttempts = "task_attempts"
    case evaluatorCalls = "evaluator_calls"
    case reflectorCalls = "reflector_calls"
    case responsesSends = "responses_sends"
    case accountedTokens = "accounted_tokens"
  }
}

package struct EvaluationLearningOwnerApprovalProjection: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let manifestSHA256: String
  package let expectedFreezeCommit: String
  package let budgets: EvaluationLearningApprovedBudgets
  package let ownerIdentity: String
  package let approvedAt: String

  package init(
    schemaVersion: Int,
    manifestSHA256: String,
    expectedFreezeCommit: String,
    budgets: EvaluationLearningApprovedBudgets,
    ownerIdentity: String,
    approvedAt: String
  ) {
    self.schemaVersion = schemaVersion
    self.manifestSHA256 = manifestSHA256
    self.expectedFreezeCommit = expectedFreezeCommit
    self.budgets = budgets
    self.ownerIdentity = ownerIdentity
    self.approvedAt = approvedAt
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case manifestSHA256 = "manifest_sha256"
    case expectedFreezeCommit = "expected_freeze_commit"
    case budgets
    case ownerIdentity = "owner_identity"
    case approvedAt = "approved_at"
  }
}

package struct EvaluationLearningOperationAuthorization: Codable, Sendable, Equatable {
  package let eventPath: String
  package let eventSHA256: String

  package init(eventPath: String, eventSHA256: String) {
    self.eventPath = eventPath
    self.eventSHA256 = eventSHA256
  }

  enum CodingKeys: String, CodingKey {
    case eventPath = "event_path"
    case eventSHA256 = "event_sha256"
  }
}

package enum EvaluationLearningClosedJSON {
  package static func decode<Value: Decodable>(
    _ type: Value.Type,
    from url: URL,
    requiredKeys: Set<String>
  ) throws -> Value {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    let object: [String: Any]
    do {
      guard
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        Set(decoded.keys) == requiredKeys
      else {
        throw EvaluationLearningAdmissionError.invalidJSON
      }
      object = decoded
    } catch let error as EvaluationLearningAdmissionError {
      throw error
    } catch {
      throw EvaluationLearningAdmissionError.invalidJSON
    }

    guard (try? EvaluationCanonicalJSON.data(fromJSONObject: object)) == data else {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
    let value: Value
    do {
      value = try JSONDecoder().decode(type, from: data)
    } catch {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
    return value
  }
}

package enum EvaluationLearningAdmissionError: Error, Sendable, Equatable {
  case invalidJSON
  case invalidBinding
  case integrityFailure
}
