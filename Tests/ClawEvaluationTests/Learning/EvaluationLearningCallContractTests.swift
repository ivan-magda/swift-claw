import ClawCore
import ClawTestSupport
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

  @Test func requestRejectsAnOpenArtifactBinding() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    var object = try jsonObject(encoding: fixture.request)
    var prompt = try #require(object["prompt"] as? [String: Any])
    prompt["label"] = "evaluator-prompt"
    object["prompt"] = prompt
    try EvaluationCanonicalJSON.data(fromJSONObject: object).write(to: fixture.requestURL)

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidJSON) {
      _ = try EvaluationLearningCallRequest.load(from: fixture.requestURL)
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
    let requestSHA256 = SHA256Digest.hex(
      try EvaluationCanonicalJSON.data(encoding: fixture.request)
    )
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
    #expect(
      Set(object.keys) == Set(EvaluationLearningCallResult.CodingKeys.allCases.map(\.rawValue))
    )
    #expect(
      Set(usageObject.keys)
        == Set(EvaluationLearningCallUsage.CodingKeys.allCases.map(\.rawValue))
    )
    #expect(
      Set(provenanceObject.keys)
        == [
          "request_sha256", "manifest_sha256", "freeze_commit", "executable_sha256",
          "prompt_sha256", "carrier_sha256",
        ]
    )
  }

  @Test(arguments: FailureAccountingFixture.allCases)
  func failedCallClassifiesHandoffWithoutPersistingProviderText(
    _ failure: FailureAccountingFixture
  ) async throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let providerText = "secret-provider-body"
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([
        .stream(HTTPStreamHead(statusCode: 200, headers: [:]), [])
      ]),
      expectedWireModel: fixture.context.route.wireModel,
      maximumResponsesSends: fixture.context.route.retryBudget
    )
    _ = try await recorder.openStream(callRequest(wireModel: fixture.context.route.wireModel))
    let providerError: any Error =
      switch failure {
      case .notStarted:
        ProviderFailure(
          cause: .terminal(status: 400, message: providerText),
          accounting: .notStarted
        )
      case .mayHaveStarted:
        ProviderFailure(
          cause: .transportFailure(message: providerText),
          accounting: .mayHaveStarted(observing: 0)
        )
      }

    // when
    let usage = try await EvaluationLearningCallUsage.recordingFailure(
      providerCallID: fixture.request.providerCallID,
      error: providerError,
      recorder: recorder,
      missingUsageTokenProxy: fixture.context.missingUsageTokenProxy
    )
    let result = try EvaluationLearningCallResult(
      request: fixture.request,
      requestSHA256: String(repeating: "a", count: 64),
      outcome: .failed,
      failureCode: "provider_failure",
      output: nil,
      finishReason: nil,
      reportedModel: nil,
      usage: usage,
      admissionContext: fixture.context
    )
    let encoded = try EvaluationCanonicalJSON.data(encoding: result)

    // then
    #expect(usage.responsesSends == 1)
    #expect(usage.provenNotStartedResponsesSends == failure.expectedProvenNotStartedSends)
    #expect(usage.accountedTokens == failure.expectedAccountedTokens)
    #expect(usage.isEstimated == failure.expectedEstimated)
    #expect(String(bytes: encoded, encoding: .utf8)?.contains(providerText) == false)
  }

  @Test func failedNoCallIsTheOnlyTerminalShapeWithoutUsage() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }

    // when
    let result = try EvaluationLearningCallResult(
      request: fixture.request,
      requestSHA256: String(repeating: "a", count: 64),
      outcome: .failedNoCall,
      failureCode: "budget_denied",
      output: nil,
      finishReason: nil,
      reportedModel: nil,
      usage: nil,
      admissionContext: fixture.context
    )

    // then
    #expect(result.outcome == .failedNoCall)
    #expect(result.failureCode == "budget_denied")
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
        requestSHA256: String(repeating: "a", count: 64),
        outcome: .failed,
        failureCode: "provider_failure",
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
    let validUsage = try EvaluationLearningCallUsage(
      providerCallID: fixture.request.providerCallID,
      responsesSends: 1,
      provenNotStartedResponsesSends: 0,
      terminalUsage: nil,
      missingUsageTokenProxy: fixture.context.missingUsageTokenProxy
    )
    let values = mutation.values(validUsage: validUsage)

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidBinding) {
      _ = try EvaluationLearningCallResult(
        request: fixture.request,
        requestSHA256: String(repeating: "a", count: 64),
        outcome: values.outcome,
        failureCode: values.failureCode,
        output: values.output,
        finishReason: nil,
        reportedModel: nil,
        usage: values.usage,
        admissionContext: fixture.context
      )
    }

    // then
    #expect(error != nil)
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

enum FailureAccountingFixture: String, CaseIterable, Sendable {
  case notStarted
  case mayHaveStarted

  var expectedProvenNotStartedSends: Int {
    self == .notStarted ? 1 : 0
  }

  var expectedAccountedTokens: Int {
    self == .notStarted ? 0 : 100
  }

  var expectedEstimated: Bool {
    self == .mayHaveStarted
  }
}

enum InvalidCallResultMutation: String, CaseIterable, Sendable {
  case responseWithFailure
  case failedWithoutUsage
  case failedWithOutput
  case failedNoCallWithUsage
  case rawFailureBody

  func values(validUsage: EvaluationLearningCallUsage) -> (
    outcome: EvaluationLearningCallOutcome,
    failureCode: String?,
    output: String?,
    usage: EvaluationLearningCallUsage?
  ) {
    switch self {
    case .responseWithFailure:
      (.response, "provider_failure", "{}", validUsage)
    case .failedWithoutUsage:
      (.failed, "provider_failure", nil, nil)
    case .failedWithOutput:
      (.failed, "provider_failure", "partial", validUsage)
    case .failedNoCallWithUsage:
      (.failedNoCall, "budget_denied", nil, validUsage)
    case .rawFailureBody:
      (.failedNoCall, "provider said: invalid bearer token", nil, nil)
    }
  }
}

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
  let resultURL =
    mutation == .resultOutsideState
    ? evaluation.appendingPathComponent("escaped-result.json")
    : results.appendingPathComponent("result.json")
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

private func jsonObject<Value: Encodable>(encoding value: Value) throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(
      with: EvaluationCanonicalJSON.data(encoding: value)
    ) as? [String: Any]
  )
}

private func callRequest(wireModel: String) -> HTTPRequest {
  HTTPRequest(
    method: .post,
    url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
    headers: [:],
    body: Data(#"{"model":"\#(wireModel)"}"#.utf8),
    timeout: .seconds(1),
    responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
  )
}
