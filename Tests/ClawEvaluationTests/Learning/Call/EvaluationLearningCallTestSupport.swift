import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawEvaluation
@testable import ClawLLM

// MARK: - Fixture

struct LearningCallFixture: Sendable {
  let root: URL
  let stateRoot: URL
  let resultURL: URL
  let executableURL: URL
  let prompt: String
  let carrier: String
  let request: EvaluationLearningCallRequest
  let requestSHA256: String
  let context: EvaluationLearningAdmissionContext

  var admissionVerifier: EvaluationLearningAdmissionVerifier {
    EvaluationLearningAdmissionVerifier(runningExecutablePath: { executableURL.path })
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  func binding(
    provider: any LLMProvider,
    wireModel: String? = nil,
    configuredReference: String? = nil,
    costPolicy: LLMCostPolicy = .includedPlan,
    reservationPolicy: LLMInputReservationPolicy = .chatGPTReplayState
  ) -> LLMRouteBinding {
    LLMRouteBinding(
      provider: provider,
      wireModel: wireModel ?? context.route.wireModel,
      configuredReference: configuredReference ?? context.route.providerReference,
      costPolicy: costPolicy,
      reservationPolicy: reservationPolicy
    )
  }

  func response(
    content: String,
    usage: ChatUsage? = ChatUsage(promptTokens: 5, completionTokens: 2, totalTokens: 7),
    toolCalls: [ToolCall] = [],
    providerState: ProviderExchangeState? = nil
  ) -> ChatResponse {
    ChatResponse(
      content: content,
      finishReason: "stop",
      usage: usage,
      costFromProvider: nil,
      toolCalls: toolCalls,
      providerState: providerState,
      reportedModel: context.route.wireModel
    )
  }

  func run(provider: SequenceProvider) async throws -> EvaluationLearningCallResult {
    try await run(binding: binding(provider: provider), liveAdmission: { .allow })
  }

  func run(
    binding: LLMRouteBinding,
    requestSHA256: String? = nil,
    prompt: String? = nil,
    carrier: String? = nil,
    liveAdmission: @escaping @Sendable () async -> ProviderRoundTripAdmission
  ) async throws -> EvaluationLearningCallResult {
    try await EvaluationLearningCallRunner().run(
      request: request,
      requestSHA256: requestSHA256 ?? self.requestSHA256,
      prompt: prompt ?? self.prompt,
      carrier: carrier ?? self.carrier,
      binding: binding,
      admissionContext: context,
      liveAdmission: liveAdmission
    )
  }

  func readDurableResult() throws -> EvaluationLearningCallResult {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: resultURL)
    return try JSONDecoder().decode(EvaluationLearningCallResult.self, from: data)
  }
}

// swiftlint:disable:next function_body_length
func makeLearningCallFixture(
  kind: EvaluationLearningOperationKind = .evaluator,
  route: EvaluationLearningRouteBinding? = nil,
  executableData: Data = Data("test executable".utf8)
) throws -> LearningCallFixture {
  let root = try makeEvaluationTestRoot()
  let evaluationRoot = root.appendingPathComponent("evaluation", isDirectory: true)
  let stateRoot = evaluationRoot.appendingPathComponent("state", isDirectory: true)
  let inputsRoot = evaluationRoot.appendingPathComponent("inputs", isDirectory: true)
  let promptRoot = root.appendingPathComponent("prompts", isDirectory: true)
  let resultsRoot = stateRoot.appendingPathComponent("results", isDirectory: true)
  let eventsRoot = evaluationRoot.appendingPathComponent("events", isDirectory: true)
  for directory in [evaluationRoot, stateRoot, inputsRoot, promptRoot, resultsRoot, eventsRoot] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  let prompt = kind == .evaluator ? "Evaluate the carrier." : "Reflect on the evidence."
  let carrier = #"{"candidate":{"output":"opaque"},"schema_version":1}"#
  let promptData = Data(prompt.utf8)
  let carrierData = Data(carrier.utf8)
  let promptURL = promptRoot.appendingPathComponent("\(kind.rawValue).txt")
  let carrierURL = inputsRoot.appendingPathComponent("carrier.json")
  try promptData.write(to: promptURL)
  try carrierData.write(to: carrierURL)

  let selectedRoute =
    route
    ?? learningRoute(
      maxOutputTokens: kind == .evaluator ? 512 : 768
    )
  let taskRoute = EvaluationLearningRouteBinding(
    providerReference: selectedRoute.providerReference,
    wireModel: selectedRoute.wireModel,
    retryBudget: 1,
    maxOutputTokens: 4_096,
    maxOutputUTF8Bytes: 32_768,
    maxOutputGraphemes: 16_384
  )
  let budgets = EvaluationLearningApprovedBudgets(
    taskAttempts: 1,
    evaluatorCalls: 2,
    reflectorCalls: 1,
    responsesSends: 6,
    accountedTokens: 10_000
  )
  let executableURL = root.appendingPathComponent("claw-eval")
  try executableData.write(to: executableURL)
  let manifestData = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "budgets": budgetObject(budgets),
    "swift_execution": [
      "evaluator_route": routeObject(
        kind == .evaluator ? selectedRoute : learningRoute(maxOutputTokens: 512)
      ),
      "executable_sha256": SHA256Digest.hex(executableData),
      "missing_usage_token_proxy": 100,
      "reflector_route": routeObject(
        kind == .reflector ? selectedRoute : learningRoute(maxOutputTokens: 768)
      ),
      "task_route": routeObject(taskRoute),
    ],
  ])
  let manifestURL = root.appendingPathComponent("manifest.json")
  try manifestData.write(to: manifestURL)
  let manifestSHA256 = SHA256Digest.hex(manifestData)
  let approvalData = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "approved_at": "2026-08-29T00:00:00Z",
    "budgets": budgetObject(budgets),
    "expected_freeze_commit": String(repeating: "a", count: 40),
    "manifest_sha256": manifestSHA256,
    "owner_identity": "owner-01",
    "schema_version": 1,
  ])
  let approvalURL = root.appendingPathComponent("owner-approval.json")
  try approvalData.write(to: approvalURL)
  let manifest = EvaluationLearningManifestBinding(
    repositoryRoot: root.path,
    evaluationRoot: evaluationRoot.path,
    manifestPath: manifestURL.path,
    manifestSHA256: manifestSHA256,
    ownerApproval: EvaluationLearningArtifactBinding(
      path: approvalURL.path,
      sha256: SHA256Digest.hex(approvalData)
    )
  )
  let providerCallID = ProviderCallID(
    rawValue: "00000000-0000-0000-0000-000000000006"
  )
  let resultURL = resultsRoot.appendingPathComponent("result.json")
  let promptBinding = EvaluationLearningArtifactBinding(
    path: promptURL.path,
    sha256: SHA256Digest.hex(promptData)
  )
  let carrierBinding = EvaluationLearningArtifactBinding(
    path: carrierURL.path,
    sha256: SHA256Digest.hex(carrierData)
  )
  let provisional = EvaluationLearningCallRequest(
    executionProfile: .scheduledLearningV1,
    jobID: "scheduled-learning-job-01",
    operationID: "evaluation-operation-01",
    attemptGeneration: 1,
    providerCallID: providerCallID,
    kind: kind,
    stateRoot: stateRoot.path,
    prompt: promptBinding,
    carrier: carrierBinding,
    resultPath: resultURL.path,
    manifest: manifest,
    authorization: EvaluationLearningOperationAuthorization(
      eventPath: eventsRoot.appendingPathComponent("operation-started.json").path,
      eventSHA256: String(repeating: "0", count: 64)
    )
  )
  let eventData = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "kind": "operation_started",
    "occurred_at": "2026-08-29T00:00:00Z",
    "payload": [
      "attempt_generation": provisional.attemptGeneration,
      "carrier_digest": carrierBinding.sha256,
      "freeze_commit": String(repeating: "a", count: 40),
      "invocation_core_digest": provisional.core.sha256,
      "job_id": provisional.jobID,
      "manifest_digest": manifestSHA256,
      "operation_id": provisional.operationID,
      "operation_kind": kind.rawValue,
      "provider_call_id": providerCallID.rawValue,
      "route_digest": SHA256Digest.hex(
        try EvaluationCanonicalJSON.data(encoding: selectedRoute)
      ),
    ],
    "schema_version": 1,
    "sequence": 1,
  ])
  let eventURL = eventsRoot.appendingPathComponent("operation-started.json")
  try eventData.write(to: eventURL)
  let request = EvaluationLearningCallRequest(
    executionProfile: provisional.executionProfile,
    jobID: provisional.jobID,
    operationID: provisional.operationID,
    attemptGeneration: provisional.attemptGeneration,
    providerCallID: providerCallID,
    kind: kind,
    stateRoot: stateRoot.path,
    prompt: promptBinding,
    carrier: carrierBinding,
    resultPath: resultURL.path,
    manifest: manifest,
    authorization: EvaluationLearningOperationAuthorization(
      eventPath: eventURL.path,
      eventSHA256: SHA256Digest.hex(eventData)
    )
  )
  let requestSHA256 = SHA256Digest.hex(try EvaluationCanonicalJSON.data(encoding: request))
  let context = EvaluationLearningAdmissionContext(
    jobID: request.jobID,
    operationID: request.operationID,
    attemptGeneration: request.attemptGeneration,
    providerCallID: providerCallID,
    manifestSHA256: manifestSHA256,
    freezeCommit: String(repeating: "a", count: 40),
    executableSHA256: SHA256Digest.hex(executableData),
    missingUsageTokenProxy: 100,
    budgets: budgets,
    route: selectedRoute
  )
  return LearningCallFixture(
    root: root,
    stateRoot: stateRoot,
    resultURL: resultURL,
    executableURL: executableURL,
    prompt: prompt,
    carrier: carrier,
    request: request,
    requestSHA256: requestSHA256,
    context: context
  )
}

func learningRoute(
  maxOutputTokens: Int,
  retryBudget: Int = 3,
  maxOutputUTF8Bytes: Int = 16_384,
  maxOutputGraphemes: Int = 4_096
) -> EvaluationLearningRouteBinding {
  EvaluationLearningRouteBinding(
    providerReference: "openai-chatgpt/gpt-5.6-sol",
    wireModel: "gpt-5.6-sol",
    retryBudget: retryBudget,
    maxOutputTokens: maxOutputTokens,
    maxOutputUTF8Bytes: maxOutputUTF8Bytes,
    maxOutputGraphemes: maxOutputGraphemes
  )
}

func budgetObject(_ budgets: EvaluationLearningApprovedBudgets) -> [String: Any] {
  [
    "accounted_tokens": budgets.accountedTokens,
    "evaluator_calls": budgets.evaluatorCalls,
    "reflector_calls": budgets.reflectorCalls,
    "responses_sends": budgets.responsesSends,
    "task_attempts": budgets.taskAttempts,
  ]
}

// MARK: - Managed provider

func learningRecorder(
  fixture: LearningCallFixture,
  transport: any HTTPExecuting & HTTPStreaming = ScriptedHTTPExecutor([
    .stream(HTTPStreamHead(statusCode: 200, headers: [:]), [])
  ])
) -> EvaluationHTTPRecorder {
  EvaluationHTTPRecorder(
    base: transport,
    expectedWireModel: fixture.context.route.wireModel,
    maximumResponsesSends: fixture.context.route.retryBudget
  )
}

func managedStack(
  fixture: LearningCallFixture,
  recorder: EvaluationHTTPRecorder
) throws -> ProviderStack {
  try ProviderStackFactory.make(
    route: try managedRoute(for: fixture.context.route),
    settings: try managedSettings(for: fixture.context.route),
    loadStaticBearer: { nil },
    makeManagedCredentialStore: {
      SeededLearningCredentialStore(credential: learningCredential())
    },
    http: recorder,
    buildVersion: "swift-claw-evaluation-v1"
  )
}

// swiftlint:disable:next function_parameter_count
func makeLearningResource(
  input: EvaluationLearningCallResourceFactoryInput,
  fixture: LearningCallFixture,
  roster: ProviderRoster,
  recorder: EvaluationHTTPRecorder,
  credentialSource: any LLMCredentialSource,
  closeTransport: @escaping @Sendable () async throws -> Void,
  liveAdmission: (@Sendable () async -> ProviderRoundTripAdmission)? = nil,
  recordResponsesSend: Bool = false
) async throws -> EvaluationLearningCallResource {
  var admission = try await input.admission(using: fixture.admissionVerifier)
  if let liveAdmission {
    admission = EvaluationLearningCallAdmission(
      context: admission.context,
      liveAdmission: liveAdmission
    )
  }
  if recordResponsesSend {
    let exchange = try await recorder.openStream(
      responsesRequest(wireModel: admission.context.route.wireModel)
    )
    _ = await exchange.cancelAndAwait()
  }
  return learningResource(
    admission: admission,
    roster: roster,
    recorder: recorder,
    credentialSource: credentialSource,
    closeTransport: closeTransport
  )
}

func learningResource(
  admission: EvaluationLearningCallAdmission,
  roster: ProviderRoster,
  recorder: EvaluationHTTPRecorder,
  credentialSource: any LLMCredentialSource,
  closeTransport: @escaping @Sendable () async throws -> Void
) -> EvaluationLearningCallResource {
  EvaluationLearningCallResource(
    admission: admission,
    roster: roster,
    credentialSource: credentialSource,
    closeTransport: closeTransport,
    observeHTTP: {
      let snapshot = await recorder.snapshot()
      return EvaluationLearningCallHTTPObservation(
        responsesSends: snapshot.responsesSends.count,
        provenNotStartedResponsesSends: snapshot.provenNotStartedResponsesSends,
        hasIntegrityFailures: snapshot.integrityFailures.isEmpty == false
      )
    },
    markProvenNotStarted: { count in
      try await recorder.recordProvenNotStartedResponsesSends(count)
    }
  )
}

func managedRoute(
  for route: EvaluationLearningRouteBinding
) throws -> ResolvedLLMRoute {
  try LLMProviderRegistry.resolve(
    modelReference: route.providerReference,
    configuredBaseURL: ""
  )
}

func managedSettings(for route: EvaluationLearningRouteBinding) throws -> LLMConfig {
  LLMConfig(
    route: try managedRoute(for: route),
    maxOutputTokens: route.maxOutputTokens,
    retryBudget: route.retryBudget,
    requestTimeoutSeconds: 180,
    streamingEnabled: false,
    structuredOutput: .off,
    fallbackRoute: nil
  )
}

func learningCredential() -> StoredOAuthCredential {
  StoredOAuthCredential(
    profileID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xAA)),
    accessToken: "access-token",
    refreshToken: "refresh-token",
    expiresAt: .distantFuture
  )
}

final class SeededLearningCredentialStore: LLMCredentialStore, @unchecked Sendable {
  private let credential: StoredOAuthCredential

  init(credential: StoredOAuthCredential) {
    self.credential = credential
  }

  func load(providerID: LLMProviderID) throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    credential
  }

  func save(
    _ credential: StoredOAuthCredential,
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) {}

  func delete(providerID: LLMProviderID) throws(LLMCredentialStoreError) {}
}

func managedSuccessEvents() -> [Data] {
  [
    responsesEvent(
      #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
    ),
    responsesEvent(
      #"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#
    ),
    responsesEvent(
      #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#
    ),
    responsesEvent(
      #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","model":"gpt-5.6-sol","usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}"#
    ),
  ]
}

func managedConflictingTerminalEvents() -> [Data] {
  managedSuccessEvents() + [
    responsesEvent(
      #"{"type":"response.done","response":{"id":"resp_1","status":"completed","model":"conflicting-model","usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}"#
    )
  ]
}

func responsesEvent(_ json: String) -> Data {
  Data("data: \(json)\n\n".utf8)
}

func responsesRequest(wireModel: String) -> HTTPRequest {
  HTTPRequest(
    method: .post,
    url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
    headers: [:],
    body: Data(#"{"model":"\#(wireModel)"}"#.utf8),
    timeout: .seconds(1),
    responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
  )
}
