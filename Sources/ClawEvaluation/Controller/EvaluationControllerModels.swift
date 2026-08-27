import Foundation

struct EvaluationPlannedAttempt: Sendable {
  let configurationPath: String
  let replacementConfigurationPath: String?
}

struct EvaluationReplicateBlock: Sendable {
  let blockID: String
  let attempts: [EvaluationPlannedAttempt]
}

struct EvaluationControllerSummary: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let completedAttemptIDs: [String]
  let incomplete: Bool
  let stopReason: String?
  let attempts: Int
  let responsesSends: Int
  let fileReads: Int
  let accountedTokens: Int
  let replacements: Int

  init(
    completedAttemptIDs: [String],
    incomplete: Bool,
    stopReason: String?,
    attempts: Int,
    responsesSends: Int,
    fileReads: Int,
    accountedTokens: Int,
    replacements: Int
  ) {
    schemaVersion = PageEvaluationContract.schemaVersion
    self.completedAttemptIDs = completedAttemptIDs
    self.incomplete = incomplete
    self.stopReason = stopReason
    self.attempts = attempts
    self.responsesSends = responsesSends
    self.fileReads = fileReads
    self.accountedTokens = accountedTokens
    self.replacements = replacements
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case completedAttemptIDs = "completed_attempt_ids"
    case incomplete
    case stopReason = "stop_reason"
    case attempts
    case responsesSends = "responses_sends"
    case fileReads = "file_reads"
    case accountedTokens = "accounted_tokens"
    case replacements
  }
}
