import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawEvaluation
@testable import ClawLLM

// swiftlint:disable file_length

@Suite struct EvaluationLearningCallTests {
  @Test func callUsesExactlyOneSystemAndOneUserMessageWithoutToolsOrSession() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let provider = SequenceProvider([fixture.response(content: #"{"answer":"ok"}"#)])

    // when
    let result = try await fixture.run(provider: provider)
    let requests = await provider.requests
    let request = try #require(requests.first)

    // then
    #expect(result.outcome == .response)
    #expect(requests.count == 1)
    #expect(request.messages.map(\.role) == [.system, .user])
    #expect(request.messages[0].content.text == fixture.prompt)
    #expect(request.messages[1].content.text == fixture.carrier)
    #expect(request.maxOutputTokens == fixture.context.route.maxOutputTokens)
    #expect(
      request.messages.allSatisfy { message in
        message.providerState == nil
      }
    )
    #expect(request.tools.isEmpty)
    #expect(request.responseFormat == nil)
    #expect(request.sessionId == nil)
    #expect(request.outputScope != nil)
  }

  @Test func invalidModelOutputIsRecordedAfterExactlyOneProviderCall() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let malformed = "not evaluator JSON"
    let provider = SequenceProvider([fixture.response(content: malformed)])

    // when
    let result = try await fixture.run(provider: provider)

    // then
    #expect(result.outcome == .response)
    #expect(result.output == malformed)
    #expect(await provider.requests.count == 1)
  }

  @Test func routeAndOutputCapMustMatchTheFrozenKind() async throws {
    // given
    let routeMismatch = try makeLearningCallFixture()
    let capMismatch = try makeLearningCallFixture(
      route: learningRoute(maxOutputTokens: 768)
    )
    let terminalMismatch = try makeLearningCallFixture()
    defer {
      routeMismatch.remove()
      capMismatch.remove()
      terminalMismatch.remove()
    }
    let routeProvider = SequenceProvider([routeMismatch.response(content: "unused")])
    let capProvider = SequenceProvider([capMismatch.response(content: "unused")])
    let mismatchedBinding = routeMismatch.binding(
      provider: routeProvider,
      wireModel: "gpt-5.6-sol-drifted"
    )
    let modelProvider = SequenceProvider([
      ChatResponse(
        content: "unusable",
        finishReason: "stop",
        usage: ChatUsage(promptTokens: 5, completionTokens: 2, totalTokens: 7),
        costFromProvider: nil,
        reportedModel: "gpt-5.6-sol-drifted"
      )
    ])
    let overCapProvider = SequenceProvider([
      terminalMismatch.response(
        content: "unusable",
        usage: ChatUsage(promptTokens: 5, completionTokens: 513, totalTokens: 518)
      )
    ])

    // when
    let routeResult = try await routeMismatch.run(
      binding: mismatchedBinding,
      liveAdmission: { .allow }
    )
    let capResult = try await capMismatch.run(provider: capProvider)
    let modelResult = try await terminalMismatch.run(provider: modelProvider)
    let usageResult = try await terminalMismatch.run(provider: overCapProvider)

    // then
    #expect(routeResult.outcome == .failedNoCall)
    #expect(routeResult.failureCode == EvaluationAttemptOutcome.harnessFailure.rawValue)
    #expect(capResult.outcome == .failedNoCall)
    #expect(capResult.failureCode == EvaluationAttemptOutcome.harnessFailure.rawValue)
    #expect(await routeProvider.requests.isEmpty)
    #expect(await capProvider.requests.isEmpty)
    #expect(modelResult.outcome == .failed)
    #expect(modelResult.failureCode == EvaluationAttemptOutcome.modelIdentityMismatch.rawValue)
    #expect(usageResult.outcome == .failed)
    #expect(usageResult.failureCode == EvaluationAttemptOutcome.budgetStopped.rawValue)
    #expect(await modelProvider.requests.count == 1)
    #expect(await overCapProvider.requests.count == 1)
  }

  @Test func resultRecordsClosedRouteUsageAndProvenance() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let output = #"{"schema_version":1,"outcome":"pass"}"#
    let providerState = ProviderExchangeState(
      issuer: "private-replay-state",
      payload: Data("opaque".utf8)
    )
    let provider = SequenceProvider([
      fixture.response(
        content: output,
        usage: ChatUsage(promptTokens: 11, completionTokens: 5, totalTokens: 16),
        providerState: providerState
      )
    ])

    // when
    let result = try await fixture.run(provider: provider)
    let encoded = try EvaluationCanonicalJSON.data(encoding: result)
    let encodedText = try #require(String(bytes: encoded, encoding: .utf8))

    // then
    #expect(result.outcome == .response)
    #expect(result.output == output)
    #expect(result.providerReference == fixture.context.route.providerReference)
    #expect(result.wireModel == fixture.context.route.wireModel)
    #expect(result.reportedModel == fixture.context.route.wireModel)
    #expect(result.retryBudget == fixture.context.route.retryBudget)
    #expect(result.maxOutputTokens == fixture.context.route.maxOutputTokens)
    #expect(result.usage?.responsesSends == 1)
    #expect(result.usage?.provenNotStartedResponsesSends == 0)
    #expect(result.usage?.reportedTotalTokens == 16)
    #expect(result.usage?.accountedTokens == 16)
    #expect(result.usage?.isEstimated == false)
    #expect(result.provenance.requestSHA256 == fixture.requestSHA256)
    #expect(result.provenance.manifestSHA256 == fixture.context.manifestSHA256)
    #expect(result.provenance.freezeCommit == fixture.context.freezeCommit)
    #expect(result.provenance.executableSHA256 == fixture.context.executableSHA256)
    #expect(result.provenance.promptSHA256 == fixture.request.prompt.sha256)
    #expect(result.provenance.carrierSHA256 == fixture.request.carrier.sha256)
    #expect(encodedText.contains("private-replay-state") == false)
    #expect(encodedText.contains("opaque") == false)
  }

  @Test func failuresBeforeAndAfterProviderHandoffHaveDifferentAccounting() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let cleanProvider = SequenceProvider(
      [],
      then: ProviderFailure(
        cause: .cleanRejection(status: 400),
        accounting: .notStarted
      )
    )
    let ambiguousProvider = SequenceProvider(
      [],
      then: ProviderFailure(
        cause: .transportFailure(message: "connection lost"),
        accounting: .mayHaveStarted(observing: 0)
      )
    )

    // when
    let clean = try await fixture.run(provider: cleanProvider)
    let ambiguous = try await fixture.run(provider: ambiguousProvider)

    // then
    #expect(clean.outcome == .failed)
    #expect(clean.usage?.responsesSends == 1)
    #expect(clean.usage?.provenNotStartedResponsesSends == 1)
    #expect(clean.usage?.accountedTokens == 0)
    #expect(clean.usage?.isEstimated == false)
    #expect(ambiguous.outcome == .failed)
    #expect(ambiguous.usage?.responsesSends == 1)
    #expect(ambiguous.usage?.provenNotStartedResponsesSends == 0)
    #expect(ambiguous.usage?.accountedTokens == fixture.context.missingUsageTokenProxy)
    #expect(ambiguous.usage?.isEstimated == true)
  }

  @Test func providerToolProposalFailsTheCallWithoutDispatchingIt() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let provider = SequenceProvider([
      fixture.response(
        content: "",
        toolCalls: [ToolCall(id: "call-1", name: "file_read", argumentsJSON: "{}")]
      )
    ])

    // when
    let result = try await fixture.run(provider: provider)

    // then
    #expect(result.outcome == .failed)
    #expect(result.failureCode == EvaluationAttemptOutcome.toolContractFailure.rawValue)
    #expect(result.output == nil)
    #expect(result.usage?.responsesSends == 1)
    #expect(await provider.requests.count == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func managedProviderRetriesWithinTheFrozenBudgetAndCountsEverySend() async throws {
    // given
    let fixture = try makeLearningCallFixture(liveAdmission: true)
    defer { fixture.remove() }
    let transport = ScriptedHTTPExecutor([
      .stream(
        HTTPStreamHead(statusCode: 500, headers: [:]),
        [
          Data(#"{"error":{"message":"retry"}}"#.utf8)
        ]
      ),
      .stream(HTTPStreamHead(statusCode: 200, headers: [:]), managedSuccessEvents()),
    ])
    let recorder = EvaluationHTTPRecorder(
      base: transport,
      expectedWireModel: fixture.context.route.wireModel,
      maximumResponsesSends: fixture.context.route.retryBudget
    )
    let stack = try ProviderStackFactory.make(
      route: try managedRoute(for: fixture.context.route),
      settings: try managedSettings(for: fixture.context.route),
      loadStaticBearer: { nil },
      makeManagedCredentialStore: {
        SeededLearningCredentialStore(credential: learningCredential())
      },
      http: recorder,
      buildVersion: "swift-claw-evaluation-v1"
    )

    // when
    let result = try await EvaluationLearningCall().run(
      request: fixture.request,
      makeResource: { _ in
        EvaluationLearningCallResource(
          roster: ProviderRoster(primary: stack.binding),
          credentialSource: stack.credentialSource,
          closeTransport: {},
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
    )

    // then
    #expect(result.outcome == .response)
    #expect(result.usage?.responsesSends == 2)
    #expect(result.usage?.provenNotStartedResponsesSends == 0)
    #expect(result.usage?.reportedTotalTokens == 7)
    #expect(
      result.usage?.accountedTokens == 7 + fixture.context.missingUsageTokenProxy
    )
    #expect(result.usage?.isEstimated == true)
    #expect(await recorder.snapshot().responsesSends.count == 2)
    #expect(await transport.recorded.count == 2)
  }

  @Test func liveCompositionVerifiesPublishesAndCleansUp() async throws {
    // given
    let fixture = try makeLearningCallFixture(liveAdmission: true)
    defer { fixture.remove() }
    let provider = SequenceProvider([fixture.response(content: #"{"schema_version":1}"#)])
    let lifecycle = LearningCallLifecycleProbe()
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([
        .stream(HTTPStreamHead(statusCode: 200, headers: [:]), [])
      ]),
      expectedWireModel: fixture.context.route.wireModel,
      maximumResponsesSends: fixture.context.route.retryBudget
    )

    // when
    let result = try await EvaluationLearningCall().run(
      request: fixture.request,
      makeResource: { admissionContext in
        await lifecycle.recordStartupAdmission(admissionContext)
        let exchange = try await recorder.openStream(
          responsesRequest(wireModel: admissionContext.route.wireModel)
        )
        _ = await exchange.cancelAndAwait()
        return EvaluationLearningCallResource(
          roster: ProviderRoster(primary: fixture.binding(provider: provider)),
          credentialSource: LearningCallCredentialSource(lifecycle: lifecycle),
          closeTransport: {
            await lifecycle.recordTransportShutdown()
          },
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
    )
    let durableData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: fixture.resultURL)
    let durable = try JSONDecoder().decode(EvaluationLearningCallResult.self, from: durableData)
    let canonical = try EvaluationCanonicalJSON.data(encoding: durable)
    let lockIsFree = try EvaluationWorkerLifecycle.proveProductionLockIsFree(
      stateRoot: fixture.stateRoot
    )

    // then
    #expect(result == durable)
    #expect(durableData == canonical)
    #expect(await lifecycle.startupAdmission == fixture.context)
    #expect(await lifecycle.credentialShutdownCount == 1)
    #expect(await lifecycle.transportShutdownCount == 1)
    #expect(await provider.requests.count == 1)
    #expect(lockIsFree)
  }
}

// MARK: - Fixture

private struct LearningCallFixture: Sendable {
  let root: URL
  let stateRoot: URL
  let resultURL: URL
  let prompt: String
  let carrier: String
  let request: EvaluationLearningCallRequest
  let requestSHA256: String
  let context: EvaluationLearningAdmissionContext

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  func binding(
    provider: any LLMProvider,
    wireModel: String? = nil,
    configuredReference: String? = nil
  ) -> LLMRouteBinding {
    LLMRouteBinding(
      provider: provider,
      wireModel: wireModel ?? context.route.wireModel,
      configuredReference: configuredReference ?? context.route.providerReference,
      costPolicy: .includedPlan,
      reservationPolicy: .chatGPTReplayState
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
    liveAdmission: @escaping @Sendable () async -> ProviderRoundTripAdmission
  ) async throws -> EvaluationLearningCallResult {
    try await EvaluationLearningCallRunner().run(
      request: request,
      requestSHA256: requestSHA256,
      prompt: prompt,
      carrier: carrier,
      binding: binding,
      admissionContext: context,
      liveAdmission: liveAdmission
    )
  }
}

// swiftlint:disable:next function_body_length
private func makeLearningCallFixture(
  kind: EvaluationLearningOperationKind = .evaluator,
  route: EvaluationLearningRouteBinding? = nil,
  liveAdmission: Bool = false
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
  let executableData: Data
  if liveAdmission {
    let executablePath = try EvaluationLearningCall.runningExecutablePath()
    executableData = try Data(contentsOf: URL(fileURLWithPath: executablePath))
  } else {
    executableData = Data("test executable".utf8)
  }
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
    prompt: prompt,
    carrier: carrier,
    request: request,
    requestSHA256: requestSHA256,
    context: context
  )
}

private func learningRoute(maxOutputTokens: Int) -> EvaluationLearningRouteBinding {
  EvaluationLearningRouteBinding(
    providerReference: "openai-chatgpt/gpt-5.6-sol",
    wireModel: "gpt-5.6-sol",
    retryBudget: 3,
    maxOutputTokens: maxOutputTokens,
    maxOutputUTF8Bytes: 16_384,
    maxOutputGraphemes: 4_096
  )
}

private func routeObject(_ route: EvaluationLearningRouteBinding) -> [String: Any] {
  [
    "max_output_graphemes": route.maxOutputGraphemes,
    "max_output_tokens": route.maxOutputTokens,
    "max_output_utf8_bytes": route.maxOutputUTF8Bytes,
    "provider_reference": route.providerReference,
    "retry_budget": route.retryBudget,
    "wire_model": route.wireModel,
  ]
}

private func budgetObject(_ budgets: EvaluationLearningApprovedBudgets) -> [String: Any] {
  [
    "accounted_tokens": budgets.accountedTokens,
    "evaluator_calls": budgets.evaluatorCalls,
    "reflector_calls": budgets.reflectorCalls,
    "responses_sends": budgets.responsesSends,
    "task_attempts": budgets.taskAttempts,
  ]
}

// MARK: - Managed provider

private func managedRoute(
  for route: EvaluationLearningRouteBinding
) throws -> ResolvedLLMRoute {
  try LLMProviderRegistry.resolve(
    modelReference: route.providerReference,
    configuredBaseURL: ""
  )
}

private func managedSettings(for route: EvaluationLearningRouteBinding) throws -> LLMConfig {
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

private func learningCredential() -> StoredOAuthCredential {
  StoredOAuthCredential(
    profileID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xAA)),
    accessToken: "access-token",
    refreshToken: "refresh-token",
    expiresAt: .distantFuture
  )
}

private final class SeededLearningCredentialStore: LLMCredentialStore, @unchecked Sendable {
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

private func managedSuccessEvents() -> [Data] {
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

private func responsesEvent(_ json: String) -> Data {
  Data("data: \(json)\n\n".utf8)
}

private func responsesRequest(wireModel: String) -> HTTPRequest {
  HTTPRequest(
    method: .post,
    url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
    headers: [:],
    body: Data(#"{"model":"\#(wireModel)"}"#.utf8),
    timeout: .seconds(1),
    responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
  )
}

// MARK: - Lifecycle

private actor LearningCallLifecycleProbe {
  private(set) var startupAdmission: EvaluationLearningAdmissionContext?
  private(set) var credentialShutdownCount = 0
  private(set) var transportShutdownCount = 0

  func recordStartupAdmission(_ context: EvaluationLearningAdmissionContext) {
    startupAdmission = context
  }

  func recordCredentialShutdown() {
    credentialShutdownCount += 1
  }

  func recordTransportShutdown() {
    transportShutdownCount += 1
  }
}

private struct LearningCallCredentialSource: LLMCredentialSource {
  let lifecycle: LearningCallLifecycleProbe

  func authorization() async throws -> LLMRequestAuthorization {
    LLMRequestAuthorization(headers: [:], redactionValues: [], generation: .zero)
  }

  func reject(
    generation: LLMCredentialGeneration,
    disposition: LLMCredentialRejection
  ) async {}

  func shutdown() async throws {
    await lifecycle.recordCredentialShutdown()
  }
}
