import AsyncHTTPClient
import ClawAgent
import ClawCore
import ClawHTTP
import ClawLLM
import ClawSecrets
import Foundation

package struct EvaluationLearningCall: Sendable {
  package init() {}

  package func run(
    request: EvaluationLearningCallRequest,
    credentialStateRoot: String
  ) async throws -> EvaluationLearningCallResult {
    return try await run(
      request: request,
      credentialStateRoot: credentialStateRoot,
      makeResource: Self.productionResourceFactory()
    )
  }

  static func productionResourceFactory(
    arguments: [String] = CommandLine.arguments
  )
    -> @Sendable (EvaluationLearningCallResourceFactoryInput) async throws ->
    EvaluationLearningCallResource
  {
    let admissionVerifier = Self.productionAdmissionVerifier(arguments: arguments)
    return { input in
      try await Self.makeLiveResource(input: input, admissionVerifier: admissionVerifier)
    }
  }

  static func productionExecutablePath(arguments: [String]) -> String {
    arguments.first ?? ""
  }

  package func run(
    request: EvaluationLearningCallRequest,
    credentialStateRoot: String,
    makeResource:
      @escaping @Sendable (
        EvaluationLearningCallResourceFactoryInput
      ) async throws -> EvaluationLearningCallResource
  ) async throws -> EvaluationLearningCallResult {
    try request.validate()
    let requestData = try EvaluationCanonicalJSON.data(encoding: request)
    let requestSHA256 = SHA256Digest.hex(requestData)
    let stateRoot = try EvaluationLearningAdmissionVerifier.absoluteURL(request.stateRoot)
    let resultURL = try EvaluationLearningAdmissionVerifier.absoluteURL(request.resultPath)
    let evaluationRoot = try EvaluationLearningAdmissionVerifier.absoluteURL(
      request.manifest.evaluationRoot
    )
    let credentialRootURL = try EvaluationCredentialStateRoot.validate(
      path: credentialStateRoot,
      evaluationRoot: evaluationRoot
    )

    return try await EvaluationWorkerLifecycle.withProductionLock(
      stateRoot: stateRoot,
      credentialStateRoot: credentialRootURL,
      makeResource: {
        let prompt = try Self.readArtifact(request.prompt)
        let carrier = try Self.readArtifact(request.carrier)
        let factoryInput = EvaluationLearningCallResourceFactoryInput(
          request: request,
          requestSHA256: requestSHA256,
          credentialStateRoot: credentialRootURL
        )
        let resource = try await makeResource(factoryInput)
        return EvaluationPreparedLearningCallResource(
          resource: resource,
          prompt: prompt,
          carrier: carrier
        )
      },
      operation: { prepared, _ in
        let resource = prepared.resource
        let context = resource.admission.context
        try Self.validate(request: request, context: context)
        guard resource.roster.hasFallback == false else {
          throw EvaluationLearningAdmissionError.invalidBinding
        }
        let result = try await EvaluationLearningCallRunner().run(
          request: request,
          requestSHA256: requestSHA256,
          prompt: prepared.prompt,
          carrier: prepared.carrier,
          binding: resource.roster.primary,
          admissionContext: context,
          liveAdmission: {
            await resource.admission.evaluate()
          }
        )
        let reconciled = try await Self.reconcile(
          result: result,
          request: request,
          requestSHA256: requestSHA256,
          context: context,
          resource: resource
        )
        let resultData = try EvaluationCanonicalJSON.data(encoding: reconciled)
        try EvaluationDurablePublication.publishExclusive(resultData, to: resultURL)
        return reconciled
      }
    )
  }
}

private struct EvaluationPreparedLearningCallResource: EvaluationWorkerResource {
  let resource: EvaluationLearningCallResource
  let prompt: String
  let carrier: String

  func shutdownCredentials() async throws {
    try await resource.shutdownCredentials()
  }

  func shutdownTransport() async throws {
    try await resource.shutdownTransport()
  }
}

package struct EvaluationLearningCallResourceFactoryInput: Sendable {
  package let request: EvaluationLearningCallRequest
  package let requestSHA256: String
  package let credentialStateRoot: URL

  package init(
    request: EvaluationLearningCallRequest,
    requestSHA256: String,
    credentialStateRoot: URL
  ) {
    self.request = request
    self.requestSHA256 = requestSHA256
    self.credentialStateRoot = credentialStateRoot
  }

  package func admission(
    using verifier: any EvaluationLearningAdmissionVerifying
  ) async throws -> EvaluationLearningCallAdmission {
    let context = try await verifier.verify(
      manifest: request.manifest,
      authorization: request.authorization,
      invocationCoreDigest: request.core.sha256,
      carrierSHA256: request.carrier.sha256,
      providerCallID: request.providerCallID,
      kind: request.kind
    )
    let liveAdmission = EvaluationLearningLiveAdmission(
      verifier: verifier,
      manifest: request.manifest,
      authorization: request.authorization,
      invocationCoreDigest: request.core.sha256,
      carrierSHA256: request.carrier.sha256,
      providerCallID: request.providerCallID,
      kind: request.kind,
      initial: context
    )
    return EvaluationLearningCallAdmission(
      context: context,
      liveAdmission: {
        do {
          _ = try EvaluationLearningCall.readArtifact(request.prompt)
          _ = try EvaluationLearningCall.readArtifact(request.carrier)
        } catch {
          return .deny(cap: "evaluation-learning-integrity")
        }
        return await liveAdmission.evaluate()
      }
    )
  }
}

package struct EvaluationLearningCallAdmission: Sendable {
  package let context: EvaluationLearningAdmissionContext
  private let liveAdmission: @Sendable () async -> ProviderRoundTripAdmission

  package init(
    context: EvaluationLearningAdmissionContext,
    liveAdmission: @escaping @Sendable () async -> ProviderRoundTripAdmission
  ) {
    self.context = context
    self.liveAdmission = liveAdmission
  }

  func evaluate() async -> ProviderRoundTripAdmission {
    await liveAdmission()
  }
}

package struct EvaluationLearningCallResource: EvaluationWorkerResource {
  package let admission: EvaluationLearningCallAdmission
  package let roster: ProviderRoster
  private let credentialSource: any LLMCredentialSource
  private let closeTransport: @Sendable () async throws -> Void
  private let observeHTTP: @Sendable () async -> EvaluationLearningCallHTTPObservation
  private let markProvenNotStarted: @Sendable (Int) async throws -> Void

  package init(
    admission: EvaluationLearningCallAdmission,
    roster: ProviderRoster,
    credentialSource: any LLMCredentialSource,
    closeTransport: @escaping @Sendable () async throws -> Void,
    observeHTTP: @escaping @Sendable () async -> EvaluationLearningCallHTTPObservation,
    markProvenNotStarted: @escaping @Sendable (Int) async throws -> Void
  ) {
    self.admission = admission
    self.roster = roster
    self.credentialSource = credentialSource
    self.closeTransport = closeTransport
    self.observeHTTP = observeHTTP
    self.markProvenNotStarted = markProvenNotStarted
  }

  func shutdownCredentials() async throws {
    try await credentialSource.shutdown()
  }

  func shutdownTransport() async throws {
    try await closeTransport()
  }

  func httpObservation() async -> EvaluationLearningCallHTTPObservation {
    await observeHTTP()
  }

  func recordProvenNotStarted(_ count: Int) async throws {
    try await markProvenNotStarted(count)
  }
}

package struct EvaluationLearningCallHTTPObservation: Sendable, Equatable {
  package let responsesSends: Int
  package let provenNotStartedResponsesSends: Int
  package let hasIntegrityFailures: Bool

  package init(
    responsesSends: Int,
    provenNotStartedResponsesSends: Int,
    hasIntegrityFailures: Bool
  ) {
    self.responsesSends = responsesSends
    self.provenNotStartedResponsesSends = provenNotStartedResponsesSends
    self.hasIntegrityFailures = hasIntegrityFailures
  }
}

// MARK: - Live Call Composition

extension EvaluationLearningCall {
  private static func productionAdmissionVerifier(
    arguments: [String]
  ) -> EvaluationLearningAdmissionVerifier {
    EvaluationLearningAdmissionVerifier(
      runningExecutablePath: {
        Self.productionExecutablePath(arguments: arguments)
      }
    )
  }

  fileprivate static func readArtifact(
    _ binding: EvaluationLearningArtifactBinding
  ) throws -> String {
    let url = try EvaluationLearningAdmissionVerifier.absoluteURL(binding.path)
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    guard
      SHA256Digest.hex(data) == binding.sha256,
      let text = String(data: data, encoding: .utf8)
    else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
    return text
  }

  private static func validate(
    request: EvaluationLearningCallRequest,
    context: EvaluationLearningAdmissionContext
  ) throws {
    let expectedOutputTokens =
      switch request.kind {
      case .evaluator: 512
      case .reflector: 768
      case .task: 0
      }
    guard
      context.jobID == request.jobID,
      context.operationID == request.operationID,
      context.attemptGeneration == request.attemptGeneration,
      context.providerCallID == request.providerCallID,
      context.manifestSHA256 == request.manifest.manifestSHA256,
      context.missingUsageTokenProxy > 0,
      context.route.retryBudget == 3,
      context.route.maxOutputTokens == expectedOutputTokens
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
  }

  // Resource construction stays linear so the catch visibly owns the transport on every failure.
  // swiftlint:disable:next function_body_length
  static func makeLiveResource(
    input: EvaluationLearningCallResourceFactoryInput,
    admissionVerifier: any EvaluationLearningAdmissionVerifying
  ) async throws -> EvaluationLearningCallResource {
    let client = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: HTTPClientProfile.protectedEgress.configuration
    )
    do {
      return try await makeLiveResource(
        input: input,
        admissionVerifier: admissionVerifier,
        http: AsyncHTTPExecutor(client: client),
        closeTransport: { try await client.shutdown() }
      )
    } catch {
      try? await client.shutdown()
      throw error
    }
  }

  static func makeLiveResource(
    input: EvaluationLearningCallResourceFactoryInput,
    admissionVerifier: any EvaluationLearningAdmissionVerifying,
    http: any HTTPExecuting & HTTPStreaming,
    closeTransport: @escaping @Sendable () async throws -> Void
  ) async throws -> EvaluationLearningCallResource {
    let admission = try await input.admission(using: admissionVerifier)
    let context = admission.context
    let route = try LLMProviderRegistry.resolve(
      modelReference: context.route.providerReference,
      configuredBaseURL: ""
    )
    guard
      route.descriptor == .openAIChatGPT,
      route.configuredReference == context.route.providerReference,
      route.wireModel == context.route.wireModel
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    let settings = LLMConfig(
      route: route,
      maxOutputTokens: context.route.maxOutputTokens,
      retryBudget: context.route.retryBudget,
      requestTimeoutSeconds: 180,
      streamingEnabled: false,
      structuredOutput: .off,
      fallbackRoute: nil
    )
    let recorder = EvaluationHTTPRecorder(
      base: http,
      expectedWireModel: context.route.wireModel,
      maximumResponsesSends: context.route.retryBudget
    )
    let stack = try ProviderStackFactory.make(
      route: route,
      settings: settings,
      loadStaticBearer: { nil },
      makeManagedCredentialStore: {
        EncryptedLLMCredentialStore(stateRoot: input.credentialStateRoot)
      },
      http: recorder,
      buildVersion: "swift-claw-evaluation-v1"
    )
    return EvaluationLearningCallResource(
      admission: admission,
      roster: ProviderRoster(primary: stack.binding),
      credentialSource: stack.credentialSource,
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

  private static func reconcile(
    result: EvaluationLearningCallResult,
    request: EvaluationLearningCallRequest,
    requestSHA256: String,
    context: EvaluationLearningAdmissionContext,
    resource: EvaluationLearningCallResource
  ) async throws -> EvaluationLearningCallResult {
    var observation = await resource.httpObservation()
    if result.usage?.provenNotStartedResponsesSends == 1 {
      let unresolved = observation.responsesSends - observation.provenNotStartedResponsesSends
      try await resource.recordProvenNotStarted(unresolved)
      observation = await resource.httpObservation()
    }
    guard observation.hasIntegrityFailures == false else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
    if result.outcome == .failedNoCall {
      guard observation.responsesSends == 0 else {
        throw EvaluationLearningAdmissionError.integrityFailure
      }
      return result
    }
    let permittedSends =
      result.outcome == .response
      ? (1...context.route.retryBudget).contains(observation.responsesSends)
      : (0...context.route.retryBudget).contains(observation.responsesSends)
    guard
      permittedSends,
      observation.provenNotStartedResponsesSends <= observation.responsesSends
    else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
    let terminalUsage: ChatUsage?
    if let usage = result.usage,
      let promptTokens = usage.promptTokens,
      let completionTokens = usage.completionTokens,
      let totalTokens = usage.reportedTotalTokens
    {
      terminalUsage = ChatUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens
      )
    } else {
      terminalUsage = nil
    }
    let usage = try EvaluationLearningCallUsage(
      providerCallID: request.providerCallID,
      responsesSends: observation.responsesSends,
      provenNotStartedResponsesSends: observation.provenNotStartedResponsesSends,
      terminalUsage: terminalUsage,
      missingUsageTokenProxy: context.missingUsageTokenProxy
    )
    return try EvaluationLearningCallResult(
      request: request,
      requestSHA256: requestSHA256,
      outcome: result.outcome,
      failureCode: result.failureCode.flatMap(EvaluationAttemptOutcome.init(rawValue:)),
      output: result.output,
      finishReason: result.finishReason,
      reportedModel: result.reportedModel,
      usage: usage,
      admissionContext: context
    )
  }
}
