import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationLearningCallContractTests {
  @Test(arguments: [
    EvaluationLearningOperationKind.evaluator,
    EvaluationLearningOperationKind.reflector,
  ])
  func requestLoadsOnlyTheTwoCallKindsAndHashesTheCanonicalCore(
    _ kind: EvaluationLearningOperationKind
  ) throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture(kind: kind)
    defer { fixture.remove() }
    try EvaluationCanonicalJSON.data(encoding: fixture.request).write(to: fixture.requestURL)
    let expectedCore = try expectedCoreData(for: fixture.request)

    // when
    let loaded = try EvaluationLearningCallRequest.load(from: fixture.requestURL)

    // then
    #expect(loaded == fixture.request)
    #expect(try EvaluationCanonicalJSON.data(encoding: loaded.core) == expectedCore)
    #expect(loaded.core.sha256 == SHA256Digest.hex(expectedCore))
    #expect(String(bytes: expectedCore, encoding: .utf8)?.contains("authorization") == false)
  }

  @Test func requestRejectsThePrimaryEvaluatorIdentityLeak() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    var object = try jsonObject(encoding: fixture.request)
    object["candidate_identity"] = "candidate-01"
    try EvaluationCanonicalJSON.data(fromJSONObject: object).write(to: fixture.requestURL)

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidJSON) {
      _ = try EvaluationLearningCallRequest.load(from: fixture.requestURL)
    }

    // then
    #expect(error != nil)
  }

  @Test(arguments: UnknownNestedCallRequestField.allCases)
  func requestRejectsAnUnknownFieldInEachClosedNestedObject(
    _ field: UnknownNestedCallRequestField
  ) throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    var object = try jsonObject(encoding: fixture.request)
    try field.addUnknownKey(to: &object)
    try EvaluationCanonicalJSON.data(fromJSONObject: object).write(to: fixture.requestURL)

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidJSON) {
      _ = try EvaluationLearningCallRequest.load(from: fixture.requestURL)
    }

    // then
    #expect(error != nil)
  }

  @Test func resultRejectsARequestDigestFromDifferentCanonicalBytes() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let usage = try EvaluationLearningCallUsage(
      providerCallID: fixture.request.providerCallID,
      responsesSends: 1,
      provenNotStartedResponsesSends: 0,
      terminalUsage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
      missingUsageTokenProxy: fixture.context.missingUsageTokenProxy
    )

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidBinding) {
      _ = try EvaluationLearningCallResult(
        request: fixture.request,
        requestSHA256: String(repeating: "0", count: 64),
        outcome: .response,
        failureCode: nil,
        output: #"{"schema_version":1}"#,
        finishReason: "stop",
        reportedModel: fixture.context.route.wireModel,
        usage: usage,
        admissionContext: fixture.context
      )
    }

    // then
    #expect(error != nil)
  }

  @Test(arguments: InvalidCallRequestMutation.allCases)
  func requestRejectsEachForbiddenKindOrPathMutation(
    _ mutation: InvalidCallRequestMutation
  ) throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture(mutation: mutation)
    defer { fixture.remove() }

    // when
    let error = #expect(throws: (any Error).self) {
      try fixture.request.validate()
    }

    // then
    #expect(error != nil)
  }

  @Test func responseFreezesIdentityAndAccountsEveryLogicalCallSend() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let requestSHA256 = try canonicalRequestSHA256(for: fixture.request)
    let usage = try EvaluationLearningCallUsage(
      providerCallID: fixture.request.providerCallID,
      responsesSends: 2,
      provenNotStartedResponsesSends: 0,
      terminalUsage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
      missingUsageTokenProxy: fixture.context.missingUsageTokenProxy
    )

    // when
    let result = try EvaluationLearningCallResult(
      request: fixture.request,
      requestSHA256: requestSHA256,
      outcome: .response,
      failureCode: nil,
      output: #"{"schema_version":1}"#,
      finishReason: "stop",
      reportedModel: fixture.context.route.wireModel,
      usage: usage,
      admissionContext: fixture.context
    )
    let encoded = try EvaluationCanonicalJSON.data(encoding: result)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let usageObject = try #require(object["usage"] as? [String: Any])
    let provenanceObject = try #require(object["provenance"] as? [String: Any])

    // then
    #expect(result.providerCallID == fixture.request.providerCallID)
    #expect(result.usage?.providerCallID == fixture.request.providerCallID)
    #expect(result.retryBudget == fixture.context.route.retryBudget)
    #expect(result.maxOutputTokens == fixture.context.route.maxOutputTokens)
    #expect(result.maxOutputUTF8Bytes == fixture.context.route.maxOutputUTF8Bytes)
    #expect(result.maxOutputGraphemes == fixture.context.route.maxOutputGraphemes)
    #expect(result.provenance.requestSHA256 == requestSHA256)
    #expect(result.provenance.manifestSHA256 == fixture.context.manifestSHA256)
    #expect(result.provenance.freezeCommit == fixture.context.freezeCommit)
    #expect(result.provenance.executableSHA256 == fixture.context.executableSHA256)
    #expect(result.provenance.promptSHA256 == fixture.request.prompt.sha256)
    #expect(result.provenance.carrierSHA256 == fixture.request.carrier.sha256)
    #expect(result.outputSHA256 == result.output.map { SHA256Digest.hex(Data($0.utf8)) })
    #expect(result.usage?.accountedTokens == 115)
    #expect(result.usage?.isEstimated == true)
    #expect(Set(object.keys) == expectedResultWireKeys)
    #expect(Set(usageObject.keys) == expectedUsageWireKeys)
    #expect(
      Set(provenanceObject.keys)
        == [
          "request_sha256", "manifest_sha256", "freeze_commit", "executable_sha256",
          "prompt_sha256", "carrier_sha256",
        ]
    )
  }

  @Test func failedNoCallIsTheOnlyTerminalShapeWithoutUsage() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }

    // when
    let result = try EvaluationLearningCallResult(
      request: fixture.request,
      requestSHA256: try canonicalRequestSHA256(for: fixture.request),
      outcome: .failedNoCall,
      failureCode: .budgetStopped,
      output: nil,
      finishReason: nil,
      reportedModel: nil,
      usage: nil,
      admissionContext: fixture.context
    )

    // then
    #expect(result.outcome == .failedNoCall)
    #expect(result.failureCode == EvaluationAttemptOutcome.budgetStopped.rawValue)
    #expect(result.usage == nil)
    #expect(result.output == nil)
    #expect(result.outputSHA256 == nil)
  }

  @Test func resultRejectsUsageFromAnotherLogicalProviderCall() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let usage = try EvaluationLearningCallUsage(
      providerCallID: ProviderCallID(
        rawValue: "00000000-0000-0000-0000-000000000099"
      ),
      responsesSends: 1,
      provenNotStartedResponsesSends: 0,
      terminalUsage: nil,
      missingUsageTokenProxy: fixture.context.missingUsageTokenProxy
    )

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidBinding) {
      _ = try EvaluationLearningCallResult(
        request: fixture.request,
        requestSHA256: try canonicalRequestSHA256(for: fixture.request),
        outcome: .failed,
        failureCode: .providerFailure,
        output: nil,
        finishReason: nil,
        reportedModel: nil,
        usage: usage,
        admissionContext: fixture.context
      )
    }

    // then
    #expect(error != nil)
  }

  @Test(arguments: InvalidCallResultMutation.allCases)
  func resultRejectsEachInvalidTerminalShapeOrAccountingMutation(
    _ mutation: InvalidCallResultMutation
  ) throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let candidate = try mutation.candidate(fixture: fixture)

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidBinding) {
      try candidate.validate(missingUsageTokenProxy: fixture.context.missingUsageTokenProxy)
    }

    // then
    #expect(error != nil)
  }

  @Test func resultRejectsAOneTokenProviderBodyAsAFailureCode() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let result = try EvaluationLearningCallResult(
      request: fixture.request,
      requestSHA256: try canonicalRequestSHA256(for: fixture.request),
      outcome: .failedNoCall,
      failureCode: .providerFailure,
      output: nil,
      finishReason: nil,
      reportedModel: nil,
      usage: nil,
      admissionContext: fixture.context
    )
    var object = try jsonObject(encoding: result)
    object["failure_code"] = "unauthorized"
    let decoded = try JSONDecoder().decode(
      EvaluationLearningCallResult.self,
      from: EvaluationCanonicalJSON.data(fromJSONObject: object)
    )

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidBinding) {
      try decoded.validate(missingUsageTokenProxy: fixture.context.missingUsageTokenProxy)
    }

    // then
    #expect(error != nil)
  }
}

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

  fileprivate func candidate(
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

private let expectedResultWireKeys: Set<String> = [
  "schema_version", "job_id", "operation_id", "attempt_generation", "provider_call_id", "kind",
  "outcome", "failure_code", "output", "output_sha256", "finish_reason", "provider_reference",
  "wire_model", "reported_model", "retry_budget", "max_output_tokens", "max_output_utf8_bytes",
  "max_output_graphemes", "usage", "provenance",
]

private let expectedUsageWireKeys: Set<String> = [
  "provider_call_id", "responses_sends", "proven_not_started_responses_sends", "prompt_tokens",
  "completion_tokens", "reported_total_tokens", "accounted_tokens", "is_estimated",
]

private struct EvaluationLearningCallFixture {
  let root: URL
  let requestURL: URL
  let request: EvaluationLearningCallRequest
  let context: EvaluationLearningAdmissionContext

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func makeEvaluationLearningCallFixture(
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

private func expectedCoreData(for request: EvaluationLearningCallRequest) throws -> Data {
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

private func canonicalRequestSHA256(for request: EvaluationLearningCallRequest) throws -> String {
  SHA256Digest.hex(try EvaluationCanonicalJSON.data(encoding: request))
}

private func jsonObject<Value: Encodable>(encoding value: Value) throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(
      with: EvaluationCanonicalJSON.data(encoding: value)
    ) as? [String: Any]
  )
}
