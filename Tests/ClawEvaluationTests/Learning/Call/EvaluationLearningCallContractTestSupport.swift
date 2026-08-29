import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

// MARK: - Fixture

enum UnknownNestedCallRequestField: String, CaseIterable, Sendable {
  case prompt
  case carrier
  case manifest
  case ownerApproval
  case authorization

  func addUnknownKey(to object: inout [String: Any]) throws {
    switch self {
    case .prompt, .carrier:
      var binding = try #require(object[rawValue] as? [String: Any])
      binding["label"] = "unapproved"
      object[rawValue] = binding
    case .manifest:
      var manifest = try #require(object["manifest"] as? [String: Any])
      manifest["candidate_identity"] = "candidate-01"
      object["manifest"] = manifest
    case .ownerApproval:
      var manifest = try #require(object["manifest"] as? [String: Any])
      var approval = try #require(manifest["owner_approval"] as? [String: Any])
      approval["owner_note"] = "unapproved"
      manifest["owner_approval"] = approval
      object["manifest"] = manifest
    case .authorization:
      var authorization = try #require(object["authorization"] as? [String: Any])
      authorization["retry_budget"] = 4
      object["authorization"] = authorization
    }
  }
}

enum InvalidCallRequestMutation: String, CaseIterable, Sendable {
  case taskKind
  case promptOutsideRepository
  case carrierOutsideEvaluation
  case stateOutsideEvaluation
  case resultOutsideState
  case symlinkedPrompt
}

enum InvalidCallResultMutation: String, CaseIterable, Sendable {
  case responseWithFailure
  case responseWithoutOutput
  case responseWithoutOutputDigest
  case responseWithoutUsage
  case responseWithoutPositiveSendUsage
  case failedWithoutUsage
  case failedWithOutput
  case failedWithoutFailureCode
  case failedWithFinishReason
  case failedWithReportedModel
  case failedNoCallWithUsage
  case failedNoCallWithOutput
  case failedNoCallWithOutputDigestOnly
  case failedNoCallWithoutFailureCode
  case failedNoCallWithFinishReason
  case failedNoCallWithReportedModel

  func candidate(
    fixture: EvaluationLearningCallFixture
  ) throws -> EvaluationLearningCallResult {
    let validUsage = try EvaluationLearningCallUsage(
      providerCallID: fixture.request.providerCallID,
      responsesSends: 1,
      provenNotStartedResponsesSends: 0,
      terminalUsage: nil,
      missingUsageTokenProxy: fixture.context.missingUsageTokenProxy
    )
    let zeroSendUsage = try EvaluationLearningCallUsage(
      providerCallID: fixture.request.providerCallID,
      responsesSends: 0,
      provenNotStartedResponsesSends: 0,
      terminalUsage: nil,
      missingUsageTokenProxy: fixture.context.missingUsageTokenProxy
    )
    let baseline: EvaluationLearningCallResult
    switch self {
    case .responseWithFailure, .responseWithoutOutput, .responseWithoutOutputDigest,
      .responseWithoutUsage, .responseWithoutPositiveSendUsage:
      baseline = try result(
        fixture: fixture,
        outcome: .response,
        failureCode: nil,
        output: "{}",
        usage: validUsage
      )
    case .failedWithoutUsage, .failedWithOutput, .failedWithoutFailureCode,
      .failedWithFinishReason, .failedWithReportedModel:
      baseline = try result(
        fixture: fixture,
        outcome: .failed,
        failureCode: .providerFailure,
        output: nil,
        usage: validUsage
      )
    case .failedNoCallWithUsage, .failedNoCallWithOutput, .failedNoCallWithOutputDigestOnly,
      .failedNoCallWithoutFailureCode, .failedNoCallWithFinishReason,
      .failedNoCallWithReportedModel:
      baseline = try result(
        fixture: fixture,
        outcome: .failedNoCall,
        failureCode: .budgetStopped,
        output: nil,
        usage: nil
      )
    }
    var object = try jsonObject(encoding: baseline)
    switch self {
    case .responseWithFailure:
      object["failure_code"] = EvaluationAttemptOutcome.providerFailure.rawValue
    case .responseWithoutOutput:
      object["output"] = NSNull()
      object["output_sha256"] = NSNull()
    case .responseWithoutOutputDigest:
      object["output_sha256"] = NSNull()
    case .responseWithoutUsage:
      object["usage"] = NSNull()
    case .responseWithoutPositiveSendUsage:
      object["usage"] = try jsonObject(encoding: zeroSendUsage)
    case .failedWithoutUsage:
      object["usage"] = NSNull()
    case .failedWithOutput, .failedNoCallWithOutput:
      object["output"] = "partial"
      object["output_sha256"] = SHA256Digest.hex(Data("partial".utf8))
    case .failedNoCallWithOutputDigestOnly:
      object["output_sha256"] = SHA256Digest.hex(Data("absent output".utf8))
    case .failedWithoutFailureCode, .failedNoCallWithoutFailureCode:
      object["failure_code"] = NSNull()
    case .failedWithFinishReason, .failedNoCallWithFinishReason:
      object["finish_reason"] = "stop"
    case .failedWithReportedModel, .failedNoCallWithReportedModel:
      object["reported_model"] = fixture.context.route.wireModel
    case .failedNoCallWithUsage:
      object["usage"] = try jsonObject(encoding: validUsage)
    }
    return try JSONDecoder().decode(
      EvaluationLearningCallResult.self,
      from: EvaluationCanonicalJSON.data(fromJSONObject: object)
    )
  }

  private func result(
    fixture: EvaluationLearningCallFixture,
    outcome: EvaluationLearningCallOutcome,
    failureCode: EvaluationAttemptOutcome?,
    output: String?,
    usage: EvaluationLearningCallUsage?
  ) throws -> EvaluationLearningCallResult {
    try EvaluationLearningCallResult(
      request: fixture.request,
      requestSHA256: canonicalRequestSHA256(for: fixture.request),
      outcome: outcome,
      failureCode: failureCode,
      output: output,
      finishReason: outcome == .response ? "stop" : nil,
      reportedModel: outcome == .response ? fixture.context.route.wireModel : nil,
      usage: usage,
      admissionContext: fixture.context
    )
  }
}

let expectedResultWireKeys: Set<String> = [
  "schema_version", "job_id", "operation_id", "attempt_generation", "provider_call_id", "kind",
  "outcome", "failure_code", "output", "output_sha256", "finish_reason", "provider_reference",
  "wire_model", "reported_model", "retry_budget", "max_output_tokens", "max_output_utf8_bytes",
  "max_output_graphemes", "usage", "provenance",
]

let expectedUsageWireKeys: Set<String> = [
  "provider_call_id", "responses_sends", "proven_not_started_responses_sends", "prompt_tokens",
  "completion_tokens", "reported_total_tokens", "accounted_tokens", "is_estimated",
]

struct EvaluationLearningCallFixture {
  let root: URL
  let requestURL: URL
  let request: EvaluationLearningCallRequest
  let context: EvaluationLearningAdmissionContext

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

func makeEvaluationLearningCallFixture(
  kind: EvaluationLearningOperationKind = .evaluator,
  mutation: InvalidCallRequestMutation? = nil
) throws -> EvaluationLearningCallFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "evaluation-learning-call-\(UUID().uuidString)",
    isDirectory: true
  )
  let evaluation = root.appendingPathComponent("evaluation", isDirectory: true)
  let state = evaluation.appendingPathComponent("state", isDirectory: true)
  let inputs = evaluation.appendingPathComponent("inputs", isDirectory: true)
  let prompts = root.appendingPathComponent("prompts", isDirectory: true)
  let results = state.appendingPathComponent("results", isDirectory: true)
  for directory in [root, evaluation, state, inputs, prompts, results] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  let promptData = Data("Evaluate the carrier.".utf8)
  let carrierData = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "candidate": ["output": "opaque"], "schema_version": 1,
  ])
  let promptTarget = prompts.appendingPathComponent("evaluator.txt")
  try promptData.write(to: promptTarget)
  let carrierTarget = inputs.appendingPathComponent("carrier.json")
  try carrierData.write(to: carrierTarget)
  let manifestURL = root.appendingPathComponent("manifest.json")
  let approvalURL = root.appendingPathComponent("owner-approval.json")
  let eventURL = evaluation.appendingPathComponent("operation-started.json")
  for file in [manifestURL, approvalURL, eventURL] {
    try Data(file.lastPathComponent.utf8).write(to: file)
  }

  let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
    "evaluation-learning-call-outside-\(UUID().uuidString)"
  )
  let promptURL: URL
  if mutation == .symlinkedPrompt {
    promptURL = prompts.appendingPathComponent("linked-prompt.txt")
    try FileManager.default.createSymbolicLink(at: promptURL, withDestinationURL: promptTarget)
  } else if mutation == .promptOutsideRepository {
    promptURL = outside
  } else {
    promptURL = promptTarget
  }
  let carrierURL = mutation == .carrierOutsideEvaluation ? outside : carrierTarget
  let stateURL = mutation == .stateOutsideEvaluation ? outside : state
  let resultURL: URL
  if mutation == .resultOutsideState {
    resultURL = evaluation.appendingPathComponent("escaped-result.json")
  } else if mutation == .stateOutsideEvaluation {
    resultURL = outside.appendingPathComponent("result.json")
  } else {
    resultURL = results.appendingPathComponent("result.json")
  }
  let providerCallID = ProviderCallID(
    rawValue: "00000000-0000-0000-0000-000000000005"
  )
  let manifest = EvaluationLearningManifestBinding(
    repositoryRoot: root.path,
    evaluationRoot: evaluation.path,
    manifestPath: manifestURL.path,
    manifestSHA256: String(repeating: "b", count: 64),
    ownerApproval: EvaluationLearningArtifactBinding(
      path: approvalURL.path,
      sha256: String(repeating: "c", count: 64)
    )
  )
  let authorization = EvaluationLearningOperationAuthorization(
    eventPath: eventURL.path,
    eventSHA256: String(repeating: "d", count: 64)
  )
  let request = EvaluationLearningCallRequest(
    executionProfile: .scheduledLearningV1,
    jobID: "scheduled-learning-job-01",
    operationID: "evaluation-operation-01",
    attemptGeneration: 1,
    providerCallID: providerCallID,
    kind: mutation == .taskKind ? .task : kind,
    stateRoot: stateURL.path,
    prompt: EvaluationLearningArtifactBinding(
      path: promptURL.path,
      sha256: SHA256Digest.hex(promptData)
    ),
    carrier: EvaluationLearningArtifactBinding(
      path: carrierURL.path,
      sha256: SHA256Digest.hex(carrierData)
    ),
    resultPath: resultURL.path,
    manifest: manifest,
    authorization: authorization
  )
  let route = EvaluationLearningRouteBinding(
    providerReference: "openai-chatgpt/gpt-5.6-sol",
    wireModel: "gpt-5.6-sol",
    retryBudget: 3,
    maxOutputTokens: 512,
    maxOutputUTF8Bytes: 16_384,
    maxOutputGraphemes: 4_096
  )
  let context = EvaluationLearningAdmissionContext(
    jobID: request.jobID,
    operationID: request.operationID,
    attemptGeneration: request.attemptGeneration,
    providerCallID: providerCallID,
    manifestSHA256: manifest.manifestSHA256,
    freezeCommit: String(repeating: "e", count: 40),
    executableSHA256: String(repeating: "f", count: 64),
    missingUsageTokenProxy: 100,
    budgets: EvaluationLearningApprovedBudgets(
      taskAttempts: 1,
      evaluatorCalls: 1,
      reflectorCalls: 1,
      responsesSends: 3,
      accountedTokens: 1_000
    ),
    route: route
  )
  return EvaluationLearningCallFixture(
    root: root,
    requestURL: state.appendingPathComponent("request.json"),
    request: request,
    context: context
  )
}

func expectedCoreData(for request: EvaluationLearningCallRequest) throws -> Data {
  try EvaluationCanonicalJSON.data(fromJSONObject: [
    "attempt_generation": request.attemptGeneration,
    "carrier": ["path": request.carrier.path, "sha256": request.carrier.sha256],
    "execution_profile": request.executionProfile.rawValue,
    "job_id": request.jobID,
    "kind": request.kind.rawValue,
    "manifest": [
      "evaluation_root": request.manifest.evaluationRoot,
      "manifest_path": request.manifest.manifestPath,
      "manifest_sha256": request.manifest.manifestSHA256,
      "owner_approval": [
        "path": request.manifest.ownerApproval.path,
        "sha256": request.manifest.ownerApproval.sha256,
      ],
      "repository_root": request.manifest.repositoryRoot,
    ],
    "operation_id": request.operationID,
    "prompt": ["path": request.prompt.path, "sha256": request.prompt.sha256],
    "provider_call_id": request.providerCallID.rawValue,
    "result_path": request.resultPath,
    "schema_version": request.schemaVersion,
    "state_root": request.stateRoot,
  ])
}

func canonicalRequestSHA256(for request: EvaluationLearningCallRequest) throws -> String {
  SHA256Digest.hex(try EvaluationCanonicalJSON.data(encoding: request))
}

func jsonObject<Value: Encodable>(encoding value: Value) throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(
      with: EvaluationCanonicalJSON.data(encoding: value)
    ) as? [String: Any]
  )
}
