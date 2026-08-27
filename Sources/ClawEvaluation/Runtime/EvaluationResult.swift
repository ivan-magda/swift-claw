import ClawAgent
import ClawCore
import Foundation

enum EvaluationAttemptOutcome: String, Codable, Sendable, Equatable {
  case completed
  case providerFailure = "provider_failure"
  case authenticationRequired = "authentication_required"
  case accessDenied = "access_denied"
  case quotaLimited = "quota_limited"
  case invalidProviderState = "invalid_provider_state"
  case localOutputLimit = "local_output_limit"
  case modelIdentityMismatch = "model_identity_mismatch"
  case budgetStopped = "budget_stopped"
  case toolContractFailure = "tool_contract_failure"
  case policyMismatch = "policy_mismatch"
  case harnessFailure = "harness_failure"
}

enum EvaluationReplacementDisposition: String, Codable, Sendable, Equatable {
  case eligible
  case ineligible
}

struct EvaluationUsageRecord: Codable, Sendable, Equatable {
  package let providerCallID: String
  package let runID: Int64?
  package let sessionID: Int64
  package let model: String
  package let promptTokens: Int
  package let completionTokens: Int
  package let totalTokens: Int
  package let isEstimated: Bool
  package let costUSD: Double
  package let costSource: String
  package let timestamp: Date

  package init(_ usage: ProviderUsage) {
    providerCallID = usage.providerCallID.rawValue
    runID = usage.runId
    sessionID = usage.sessionId
    model = usage.model
    promptTokens = usage.promptTokens
    completionTokens = usage.completionTokens
    totalTokens = SaturatingArithmetic.sum(
      max(0, usage.promptTokens),
      max(0, usage.completionTokens)
    )
    isEstimated = usage.isEstimated
    costUSD = usage.costUSD
    costSource = usage.costSource.rawValue
    timestamp = usage.ts
  }

  enum CodingKeys: String, CodingKey {
    case providerCallID = "provider_call_id"
    case runID = "run_id"
    case sessionID = "session_id"
    case model
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case totalTokens = "total_tokens"
    case isEstimated = "is_estimated"
    case costUSD = "cost_usd"
    case costSource = "cost_source"
    case timestamp
  }
}

struct EvaluationAttemptResult: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let attemptID: String
  package let fixtureID: String
  package let taskID: String
  package let split: String
  package let stage: String
  package let frozenOrderIndex: Int
  package let frozenOrderKey: String
  package let replicate: Int
  package let condition: EvaluationCondition
  package let processUUID: UUID
  package let processID: Int32
  package let lockAcquisitionID: UUID?
  package let runID: Int64
  package let sessionID: Int64
  package let conversationID: String
  package let startedAt: String
  package let finishedAt: String
  package let durationMilliseconds: Int64
  package let protocolSHA256: String
  package let manifestSHA256: String
  package let approval: EvaluationApprovalBinding
  package let provenance: EvaluationFrozenProvenance
  package let inputSHA256: String
  package let taskPromptSHA256: String
  package let lessonSetDigest: String
  package let lessonSetID: String
  package let lessonIDs: [String]
  package let carrierReceipt: EvaluationCarrierReceipt
  package let carrierReceiptSHA256: String
  package let policyVersion: String
  package let providerReference: String
  package let wireModel: String
  package let transportMode: EvaluationTransportMode
  package let fallbackReference: String?
  package let outcome: EvaluationAttemptOutcome
  package let criticalCode: String?
  package let rawOutput: String?
  package let modelObservations: [ModelRoundTripObservation]
  package let http: EvaluationHTTPSnapshot
  package let outputCounts: AttemptOutputCounts?
  package let tools: [EvaluationToolRecord]
  package let audit: [EvaluationAuditRecord]
  package let usage: [EvaluationUsageRecord]
  package let accountedTokens: Int
  package let replacementDisposition: EvaluationReplacementDisposition
  package let replacementReason: String
  package let replacementOfAttemptID: String?
  package let replacementOrdinal: Int
  package let workspace: EvaluationWorkspaceMaterialization

  package init(
    configuration: EvaluationAttemptConfiguration,
    processUUID: UUID,
    processID: Int32,
    runID: Int64,
    sessionID: Int64,
    startedAt: String,
    finishedAt: String,
    durationMilliseconds: Int64,
    policyVersion: String,
    outcome: EvaluationAttemptOutcome,
    criticalCode: String?,
    rawOutput: String?,
    modelObservations: [ModelRoundTripObservation],
    http: EvaluationHTTPSnapshot,
    outputCounts: AttemptOutputCounts?,
    tools: [EvaluationToolRecord],
    audit: [EvaluationAuditRecord] = [],
    usage: [EvaluationUsageRecord],
    accountedTokens: Int,
    replacementDisposition: EvaluationReplacementDisposition,
    replacementReason: String,
    workspace: EvaluationWorkspaceMaterialization,
    lockAcquisitionID: UUID? = nil
  ) {
    schemaVersion = PageEvaluationContract.schemaVersion
    attemptID = configuration.attemptID
    fixtureID = configuration.fixtureID
    taskID = configuration.taskID
    split = configuration.split
    stage = configuration.stage
    frozenOrderIndex = configuration.frozenOrderIndex
    frozenOrderKey = configuration.frozenOrderKey
    replicate = configuration.replicate
    condition = configuration.condition
    self.processUUID = processUUID
    self.processID = processID
    self.lockAcquisitionID = lockAcquisitionID
    self.runID = runID
    self.sessionID = sessionID
    conversationID = "\(processUUID.uuidString.lowercased()):\(configuration.attemptID)"
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.durationMilliseconds = durationMilliseconds
    protocolSHA256 = configuration.protocolSHA256
    manifestSHA256 = configuration.approval.manifestSHA256
    approval = configuration.approval
    provenance = configuration.provenance
    inputSHA256 = configuration.inputSHA256
    taskPromptSHA256 = configuration.taskPromptSHA256
    lessonSetDigest = configuration.lessonSetDigest
    lessonSetID = workspace.lessonSetID
    lessonIDs = workspace.lessonIDs
    carrierReceipt = workspace.carrierReceipt
    carrierReceiptSHA256 = workspace.carrierReceiptSHA256
    self.policyVersion = policyVersion
    providerReference = configuration.providerReference
    wireModel = configuration.wireModel
    transportMode = configuration.transportMode
    fallbackReference = configuration.fallbackReference
    self.outcome = outcome
    self.criticalCode = criticalCode
    self.rawOutput = rawOutput
    self.modelObservations = modelObservations
    self.http = http
    self.outputCounts = outputCounts
    self.tools = tools
    self.audit = audit
    self.usage = usage
    self.accountedTokens = accountedTokens
    self.replacementDisposition = replacementDisposition
    self.replacementReason = replacementReason
    replacementOfAttemptID = configuration.replacementOfAttemptID
    replacementOrdinal = configuration.replacementOrdinal
    self.workspace = workspace
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case attemptID = "attempt_id"
    case fixtureID = "fixture_id"
    case taskID = "task_id"
    case split
    case stage
    case frozenOrderIndex = "frozen_order_index"
    case frozenOrderKey = "frozen_order_key"
    case replicate
    case condition
    case processUUID = "process_uuid"
    case processID = "process_id"
    case lockAcquisitionID = "lock_acquisition_id"
    case runID = "run_id"
    case sessionID = "session_id"
    case conversationID = "conversation_id"
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case durationMilliseconds = "duration_milliseconds"
    case protocolSHA256 = "protocol_sha256"
    case manifestSHA256 = "manifest_sha256"
    case approval
    case provenance
    case inputSHA256 = "input_sha256"
    case taskPromptSHA256 = "task_prompt_sha256"
    case lessonSetDigest = "lesson_set_digest"
    case lessonSetID = "lesson_set_id"
    case lessonIDs = "lesson_ids"
    case carrierReceipt = "carrier_receipt"
    case carrierReceiptSHA256 = "carrier_receipt_sha256"
    case policyVersion = "policy_version"
    case providerReference = "provider_reference"
    case wireModel = "wire_model"
    case transportMode = "transport_mode"
    case fallbackReference = "fallback_reference"
    case outcome
    case criticalCode = "critical_code"
    case rawOutput = "raw_output"
    case modelObservations = "model_observations"
    case http
    case outputCounts = "output_counts"
    case tools
    case audit
    case usage
    case accountedTokens = "accounted_tokens"
    case replacementDisposition = "replacement_disposition"
    case replacementReason = "replacement_reason"
    case replacementOfAttemptID = "replacement_of_attempt_id"
    case replacementOrdinal = "replacement_ordinal"
    case workspace
  }
}

enum EvaluationResultAccounting {
  package static func accountedTokens(
    responsesSends: Int,
    provenNotStartedResponsesSends: Int = 0,
    usage: [ProviderUsage]
  ) -> Int {
    accountedTokens(
      responsesSends: responsesSends,
      provenNotStartedResponsesSends: provenNotStartedResponsesSends,
      usage: usage.map { row in
        EvaluationUsageAccountingRow(
          tokens: SaturatingArithmetic.sum(
            max(0, row.promptTokens),
            max(0, row.completionTokens)
          ),
          isEstimated: row.isEstimated
        )
      }
    )
  }

  static func accountedTokens(
    responsesSends: Int,
    provenNotStartedResponsesSends: Int,
    usage: [EvaluationUsageAccountingRow]
  ) -> Int {
    let safeSends = max(0, responsesSends)
    let accountableSends = max(0, safeSends - max(0, provenNotStartedResponsesSends))
    let reported = usage.prefix(accountableSends).reduce(0) { total, row in
      let rowTokens =
        row.isEstimated
        ? PageEvaluationContract.missingUsageTokenProxy
        : max(0, row.tokens)
      return SaturatingArithmetic.sum(total, rowTokens)
    }
    let missing = max(0, accountableSends - usage.count)
    let missingTokens = SaturatingArithmetic.product(
      missing,
      PageEvaluationContract.missingUsageTokenProxy
    )
    return SaturatingArithmetic.sum(reported, missingTokens)
  }
}

struct EvaluationUsageAccountingRow: Sendable, Equatable {
  let tokens: Int
  let isEstimated: Bool
}
