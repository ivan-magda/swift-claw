import AsyncHTTPClient
import ClawAgent
import ClawCore
import ClawHTTP
import ClawLLM
import ClawSecrets
import Foundation

struct EvaluationLiveFreezeAdmission: Sendable {
  let verifier: any EvaluationFreezeVerifying
  let inputs: EvaluationFreezeInputs
  let initial: EvaluationFreezeContext

  func evaluate() async -> ProviderRoundTripAdmission {
    do {
      let refreshed = try await verifier.verify(inputs)

      guard refreshed.hasSameApprovedBinding(as: initial) else {
        return .deny(cap: "evaluation-freeze-integrity")
      }

      try EvaluationProtectedClosure.verify(refreshed)
      return .allow
    } catch {
      return .deny(cap: "evaluation-freeze-integrity")
    }
  }
}

struct EvaluationWorkerBatchConfiguration: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let attemptConfigurationPaths: [String]

  package init(
    schemaVersion: Int = PageEvaluationContract.schemaVersion,
    attemptConfigurationPaths: [String]
  ) {
    self.schemaVersion = schemaVersion
    self.attemptConfigurationPaths = attemptConfigurationPaths
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case attemptConfigurationPaths = "attempt_configuration_paths"
  }
}

struct EvaluationLiveResource: EvaluationWorkerResource {
  package let roster: ProviderRoster
  package let httpRecorder: EvaluationHTTPRecorder
  private let credentialSource: any LLMCredentialSource
  private let closeTransport: @Sendable () async throws -> Void

  init(
    roster: ProviderRoster,
    httpRecorder: EvaluationHTTPRecorder,
    credentialSource: any LLMCredentialSource,
    closeTransport: @escaping @Sendable () async throws -> Void
  ) {
    self.roster = roster
    self.httpRecorder = httpRecorder
    self.credentialSource = credentialSource
    self.closeTransport = closeTransport
  }

  package func shutdownCredentials() async throws {
    try await credentialSource.shutdown()
  }

  package func shutdownTransport() async throws {
    try await closeTransport()
  }
}

enum EvaluationLiveResourceFactory {
  package static func make(
    configuration: EvaluationAttemptConfiguration,
    credentialStateRoot: URL,
    progressRecorder: EvaluationAttemptProgressRecorder? = nil
  ) async throws -> EvaluationLiveResource {
    let client = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: HTTPClientProfile.protectedEgress.configuration
    )
    let executor = AsyncHTTPExecutor(client: client)
    do {
      return try await make(
        configuration: configuration,
        credentialStateRoot: credentialStateRoot,
        progressRecorder: progressRecorder,
        http: executor,
        closeTransport: { try await client.shutdown() }
      )
    } catch {
      try? await client.shutdown()
      throw error
    }
  }

  static func make(
    configuration: EvaluationAttemptConfiguration,
    credentialStateRoot: URL,
    progressRecorder: EvaluationAttemptProgressRecorder? = nil,
    http: any HTTPExecuting & HTTPStreaming,
    closeTransport: @escaping @Sendable () async throws -> Void
  ) async throws -> EvaluationLiveResource {
    let recorder = EvaluationHTTPRecorder(
      base: http,
      expectedWireModel: configuration.wireModel,
      maximumResponsesSends: PageEvaluationContract.maximumResponsesSendsPerAttempt,
      progressRecorder: progressRecorder,
      attemptID: configuration.attemptID
    )
    let route = ResolvedLLMRoute(
      descriptor: .openAIChatGPT,
      configuredReference: configuration.providerReference,
      wireModel: configuration.wireModel
    )
    let settings = LLMConfig(
      route: route,
      maxOutputTokens: PageEvaluationContract.runBudget.maxOutputTokens,
      retryBudget: PageEvaluationContract.runBudget.retryBudget,
      requestTimeoutSeconds: PageEvaluationContract.runBudget.wallClockDeadlineSeconds,
      streamingEnabled: true,
      structuredOutput: .off,
      fallbackRoute: nil
    )

    let stack = try ProviderStackFactory.make(
      route: route,
      settings: settings,
      loadStaticBearer: { nil },
      makeManagedCredentialStore: {
        EncryptedLLMCredentialStore(stateRoot: credentialStateRoot)
      },
      http: recorder,
      buildVersion: "swift-claw-evaluation-v1"
    )
    return EvaluationLiveResource(
      roster: ProviderRoster(primary: stack.binding),
      httpRecorder: recorder,
      credentialSource: stack.credentialSource,
      closeTransport: closeTransport
    )
  }
}

package struct EvaluationWorker: Sendable {
  package init() {}

  package func run(
    invocation: EvaluationWorkerInvocation,
    credentialStateRoot: String,
    sealedOutputKey: Data? = nil
  ) async throws -> String {
    try await runResult(
      invocation: invocation,
      credentialStateRoot: credentialStateRoot,
      sealedOutputKey: sealedOutputKey,
      freezeVerifier: EvaluationLiveFreezeVerifier()
    ).attemptID
  }

  // swiftlint:disable:next function_body_length
  func runResult(
    invocation: EvaluationWorkerInvocation,
    credentialStateRoot: String,
    sealedOutputKey: Data? = nil,
    freezeVerifier: any EvaluationFreezeVerifying
  ) async throws -> EvaluationAttemptResult {
    try invocation.validate()
    guard invocation.kind == .attempt else {
      throw EvaluationWorkerInvocationError.kindMismatch
    }
    let snapshot = try EvaluationWorkerConfigurationSnapshot.load(
      kind: invocation.kind,
      path: invocation.configurationPath
    )
    guard snapshot.sha256 == invocation.configurationSHA256 else {
      throw EvaluationWorkerInvocationError.invalidConfigurationSnapshot
    }
    let configuration = try snapshot.decodeAttempt()
    let credentialRootURL = try EvaluationCredentialStateRoot.validateLegacy(
      path: credentialStateRoot,
      expectedStateRoot: configuration.stateRootURL
    )
    let freeze = try await freezeVerifier.verifyLocal(invocation.freeze)
    let liveAdmission = EvaluationLiveFreezeAdmission(
      verifier: freezeVerifier,
      inputs: invocation.freeze,
      initial: freeze
    )

    try EvaluationControllerJournal.authorize(
      invocation.authorization,
      invocationID: invocation.invocationID,
      invocationCoreSHA256: invocation.core.sha256,
      attemptIDs: [configuration.attemptID],
      manifestSHA256: freeze.receipt.manifest.sha256,
      freezeCommit: freeze.receipt.freezeCommit,
      fixedTimestamp: freeze.runtime.fixedTimestamp,
      evaluationRoot: freeze.runtime.evaluationRootURL
    )
    try EvaluationController.authorizeAttempt(configuration, against: freeze)
    try configuration.validate()
    guard
      FileManager.default.fileExists(
        atPath: EvaluationWorkerFailureEvidence.url(for: configuration.resultURL).path
      ) == false
    else {
      throw EvaluationWorkerError.staleFailureEvidence
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [
        configuration.evaluationRootURL,
        configuration.stateRootURL,
        configuration.workspaceRootURL,
      ]
    )
    let progressRecorder = try EvaluationAttemptProgressRecorder.start(
      invocation: invocation,
      configurations: [configuration]
    )
    let result = try await Self.preservingFailureEvidence(
      invocation: invocation,
      configuration: configuration
    ) {
      if let mismatch = EvaluationPolicyInspector.mismatch(for: configuration) {
        throw mismatch
      }
      return try await EvaluationWorkerLifecycle.withProductionLock(
        stateRoot: configuration.stateRootURL,
        credentialStateRoot: credentialRootURL,
        makeResource: {
          try await EvaluationLiveResourceFactory.make(
            configuration: configuration,
            credentialStateRoot: credentialRootURL,
            progressRecorder: progressRecorder
          )
        },
        operation: { resource, lockAcquisitionID in
          try await EvaluationAttemptRunner(
            roster: resource.roster,
            httpRecorder: resource.httpRecorder,
            progressRecorder: progressRecorder
          ).run(
            configuration: configuration,
            sendBudget: invocation.budget,
            lockAcquisitionID: lockAcquisitionID,
            integrityAdmission: {
              await liveAdmission.evaluate()
            }
          )
        }
      )
    }
    if configuration.requiresJointUnseal {
      guard let sealedOutputKey else {
        throw EvaluationWorkerError.sealedOutputKeyRequired
      }
      try EvaluationSealedResultStore.seal(
        result,
        keyData: sealedOutputKey,
        resultURL: configuration.resultURL
      )
    } else {
      guard sealedOutputKey == nil else {
        throw EvaluationWorkerError.unexpectedSealedOutputKey
      }
      try EvaluationJSONFile.write(result, to: configuration.resultURL)
    }
    return result
  }

  /// Runs the clean/non-empty half of the restart canary in one operating-system process while
  /// preserving a fresh runtime, provider exchange, and conversation for each attempt.
  package func runCanaryProcess(
    invocation: EvaluationWorkerInvocation
  ) async throws -> [String] {
    try await runCanaryResults(
      invocation: invocation,
      freezeVerifier: EvaluationLiveFreezeVerifier()
    ).map(\.attemptID)
  }

  // swiftlint:disable:next function_body_length
  func runCanaryResults(
    invocation: EvaluationWorkerInvocation,
    freezeVerifier: any EvaluationFreezeVerifying
  ) async throws -> [EvaluationAttemptResult] {
    try invocation.validate()
    guard invocation.kind == .canaryProcess else {
      throw EvaluationWorkerInvocationError.kindMismatch
    }
    let snapshot = try EvaluationWorkerConfigurationSnapshot.load(
      kind: invocation.kind,
      path: invocation.configurationPath
    )
    guard snapshot.sha256 == invocation.configurationSHA256 else {
      throw EvaluationWorkerInvocationError.invalidConfigurationSnapshot
    }
    let attempts = try snapshot.decodeCanaryAttempts()
    let freeze = try await freezeVerifier.verifyLocal(invocation.freeze)
    let liveAdmission = EvaluationLiveFreezeAdmission(
      verifier: freezeVerifier,
      inputs: invocation.freeze,
      initial: freeze
    )

    try EvaluationControllerJournal.authorize(
      invocation.authorization,
      invocationID: invocation.invocationID,
      invocationCoreSHA256: invocation.core.sha256,
      attemptIDs: attempts.map(\.attemptID),
      manifestSHA256: freeze.receipt.manifest.sha256,
      freezeCommit: freeze.receipt.freezeCommit,
      fixedTimestamp: freeze.runtime.fixedTimestamp,
      evaluationRoot: freeze.runtime.evaluationRootURL
    )
    for attempt in attempts {
      try attempt.validate()
      guard
        FileManager.default.fileExists(
          atPath: EvaluationWorkerFailureEvidence.url(for: attempt.resultURL).path
        ) == false
      else {
        throw EvaluationWorkerError.staleFailureEvidence
      }
    }
    try EvaluationController.authorizeCanaryProcess(attempts, against: freeze)
    guard
      attempts[0].evaluationRoot == attempts[1].evaluationRoot,
      attempts[0].lessonSource == .clean,
      attempts[1].lessonSource != .clean,
      attempts[0].attemptID != attempts[1].attemptID
    else {
      throw EvaluationWorkerError.invalidCanaryProcessConfiguration
    }
    let processUUID = UUID()
    let progressRecorder = try EvaluationAttemptProgressRecorder.start(
      invocation: invocation,
      configurations: attempts
    )
    return try await EvaluationWorkerLifecycle.withProductionLockOnly(
      stateRoot: attempts[0].stateRootURL
    ) { lockAcquisitionID in
      var results: [EvaluationAttemptResult] = []
      var sendBudget = invocation.budget
      for attempt in attempts {
        let currentSendBudget = sendBudget
        let result = try await Self.preservingFailureEvidence(
          invocation: invocation,
          configuration: attempt
        ) {
          if let mismatch = EvaluationPolicyInspector.mismatch(for: attempt) {
            throw mismatch
          }
          return try await EvaluationWorkerLifecycle.withResource(
            makeResource: {
              try await EvaluationLiveResourceFactory.make(
                configuration: attempt,
                credentialStateRoot: attempt.stateRootURL,
                progressRecorder: progressRecorder
              )
            },
            operation: { resource in
              try await EvaluationAttemptRunner(
                roster: resource.roster,
                httpRecorder: resource.httpRecorder,
                progressRecorder: progressRecorder,
                processUUID: processUUID
              ).run(
                configuration: attempt,
                sendBudget: currentSendBudget,
                lockAcquisitionID: lockAcquisitionID,
                integrityAdmission: {
                  await liveAdmission.evaluate()
                }
              )
            }
          )
        }
        try EvaluationJSONFile.write(result, to: attempt.resultURL)
        results.append(result)
        sendBudget = sendBudget.advanced(by: result)
      }
      return results
    }
  }

  private static func preservingFailureEvidence<Result: Sendable>(
    invocation: EvaluationWorkerInvocation,
    configuration: EvaluationAttemptConfiguration,
    operation: () async throws -> Result
  ) async throws -> Result {
    do {
      return try await operation()
    } catch let error as EvaluationWorkspaceError {
      try EvaluationWorkerFailureEvidence.publish(
        error,
        invocation: invocation,
        configuration: configuration
      )
      throw error
    } catch let error as EvaluationAttemptError {
      try EvaluationWorkerFailureEvidence.publishIfClassified(
        error,
        invocation: invocation,
        configuration: configuration
      )
      throw error
    }
  }
}

extension EvaluationWorker {
  package func run(
    invocation: EvaluationLearningTaskInvocation,
    credentialStateRoot: String
  ) async throws -> String {
    try await runResult(
      invocation: invocation,
      credentialStateRoot: credentialStateRoot,
      admissionVerifier: EvaluationLearningAdmissionVerifier()
    ).attemptID
  }

  // swiftlint:disable:next function_body_length
  func runResult(
    invocation: EvaluationLearningTaskInvocation,
    credentialStateRoot: String,
    admissionVerifier: any EvaluationLearningAdmissionVerifying,
    makeResource:
      @escaping @Sendable (
        EvaluationAttemptConfiguration, URL
      ) async throws -> EvaluationLiveResource = { configuration, credentialRoot in
        try await EvaluationLiveResourceFactory.make(
          configuration: configuration,
          credentialStateRoot: credentialRoot
        )
      }
  ) async throws -> EvaluationAttemptResult {
    try invocation.validate()
    let configurationURL = URL(fileURLWithPath: invocation.configurationPath)
    let configurationData = try EvaluationPathSecurity.readRegularSingleLinkFile(
      at: configurationURL
    )
    guard SHA256Digest.hex(configurationData) == invocation.configurationSHA256 else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
    let configuration = try JSONDecoder().decode(
      EvaluationAttemptConfiguration.self,
      from: configurationData
    )
    try configuration.validate()
    let credentialRootURL = try EvaluationCredentialStateRoot.validate(
      path: credentialStateRoot,
      evaluationRoot: configuration.evaluationRootURL
    )
    guard
      configuration.executionProfile == invocation.executionProfile,
      let carrierSHA256 = configuration.carrierSHA256
    else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }

    let initialAdmission = try await admissionVerifier.verify(
      manifest: invocation.manifest,
      authorization: invocation.authorization,
      invocationCoreDigest: invocation.core.sha256,
      carrierSHA256: carrierSHA256,
      providerCallID: invocation.providerCallID,
      kind: .task
    )
    try Self.validateLearningAdmission(
      initialAdmission,
      invocation: invocation,
      configuration: configuration
    )
    try invocation.budget.validateScheduledLearning(
      approvedBudgets: initialAdmission.budgets
    )
    try EvaluationWorkspaceMaterializer.verifyPromotionReceipt(configuration: configuration)
    let liveAdmission = EvaluationLearningLiveAdmission(
      verifier: admissionVerifier,
      manifest: invocation.manifest,
      authorization: invocation.authorization,
      invocationCoreDigest: invocation.core.sha256,
      carrierSHA256: carrierSHA256,
      providerCallID: invocation.providerCallID,
      kind: .task,
      initial: initialAdmission
    )

    guard FileManager.default.fileExists(atPath: configuration.resultURL.path) == false else {
      throw EvaluationWorkerError.staleResult
    }
    guard
      FileManager.default.fileExists(
        atPath: EvaluationWorkerFailureEvidence.url(for: configuration.resultURL).path
      ) == false
    else {
      throw EvaluationWorkerError.staleFailureEvidence
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [
        configuration.evaluationRootURL,
        configuration.stateRootURL,
        configuration.workspaceRootURL,
      ]
    )

    let result = try await EvaluationWorkerLifecycle.withProductionLock(
      stateRoot: configuration.stateRootURL,
      credentialStateRoot: credentialRootURL,
      makeResource: {
        try await makeResource(configuration, credentialRootURL)
      },
      operation: { resource, lockAcquisitionID in
        try await EvaluationAttemptRunner(
          roster: resource.roster,
          httpRecorder: resource.httpRecorder,
          providerCallIDGenerator: EvaluationLearningProviderCallIDGenerator(
            first: invocation.providerCallID
          )
        ).run(
          configuration: configuration,
          sendBudget: invocation.budget,
          lockAcquisitionID: lockAcquisitionID,
          integrityAdmission: {
            await liveAdmission.evaluate()
          }
        )
      }
    )
    try EvaluationDurablePublication.publish(
      EvaluationCanonicalJSON.data(encoding: result),
      to: configuration.resultURL
    )
    return result
  }
}

enum EvaluationWorkerError: Error, Sendable, Equatable {
  case invalidCanaryProcessConfiguration
  case staleResult
  case staleFailureEvidence
  case sealedOutputKeyRequired
  case unexpectedSealedOutputKey
}

private extension EvaluationWorker {
  static func validateLearningAdmission(
    _ admission: EvaluationLearningAdmissionContext,
    invocation: EvaluationLearningTaskInvocation,
    configuration: EvaluationAttemptConfiguration
  ) throws {
    let route = admission.route
    let budgets = admission.budgets
    guard
      admission.jobID == invocation.jobID,
      admission.operationID == invocation.operationID,
      admission.attemptGeneration == invocation.attemptGeneration,
      admission.providerCallID == invocation.providerCallID,
      admission.manifestSHA256 == invocation.manifest.manifestSHA256,
      admission.manifestSHA256 == configuration.approval.manifestSHA256,
      admission.freezeCommit == configuration.provenance.freezeCommit,
      admission.executableSHA256 == configuration.provenance.executableSHA256,
      configuration.evaluationRoot == invocation.manifest.evaluationRoot,
      admission.missingUsageTokenProxy == PageEvaluationContract.missingUsageTokenProxy,
      budgets.taskAttempts > 0,
      budgets.evaluatorCalls > 0,
      budgets.reflectorCalls > 0,
      budgets.responsesSends > 0,
      budgets.accountedTokens > 0,
      route.providerReference == configuration.providerReference,
      route.providerReference == PageEvaluationContract.providerReference,
      route.wireModel == configuration.wireModel,
      route.wireModel == PageEvaluationContract.wireModel,
      route.retryBudget == PageEvaluationContract.runBudget.retryBudget,
      route.maxOutputTokens == PageEvaluationContract.runBudget.maxOutputTokens,
      route.maxOutputUTF8Bytes == PageEvaluationContract.outputLimits.maximumUTF8Bytes,
      route.maxOutputGraphemes == PageEvaluationContract.outputLimits.maximumGraphemes
    else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
  }
}
