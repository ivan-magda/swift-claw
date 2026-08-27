import AsyncHTTPClient
import ClawAgent
import ClawCore
import ClawHTTP
import ClawLLM
import ClawSecrets
import ClawSubprocess
import Foundation

protocol EvaluationWorkerResource: Sendable {
  func shutdownCredentials() async throws
  func shutdownTransport() async throws
}

enum EvaluationWorkerLifecycle {
  package static func withProductionLock<Resource: EvaluationWorkerResource, Value: Sendable>(
    stateRoot: URL,
    makeResource: @Sendable () async throws -> Resource,
    operation: @Sendable (Resource, UUID) async throws -> Value
  ) async throws -> Value {
    try await withProductionLockOnly(stateRoot: stateRoot) { lockAcquisitionID in
      try await withResource(makeResource: makeResource) { resource in
        try await operation(resource, lockAcquisitionID)
      }
    }
  }

  package static func withProductionLockOnly<Value: Sendable>(
    stateRoot: URL,
    operation: @Sendable (UUID) async throws -> Value
  ) async throws -> Value {
    try EvaluationPathSecurity.ensurePrivateDirectory(at: stateRoot)

    let lockPath = SecretStatePaths(stateRoot: stateRoot).instanceLock.path
    let lock = try InstanceLock(path: lockPath)
    let lockAcquisitionID = UUID()
    do {
      let value = try await operation(lockAcquisitionID)
      lock.release()
      return value
    } catch {
      lock.release()
      throw error
    }
  }

  static func proveProductionLockIsFree(stateRoot: URL) throws -> Bool {
    try EvaluationPathSecurity.ensurePrivateDirectory(at: stateRoot)
    let lock = try InstanceLock(path: SecretStatePaths(stateRoot: stateRoot).instanceLock.path)
    lock.release()
    return true
  }

  package static func withResource<Resource: EvaluationWorkerResource, Value: Sendable>(
    makeResource: @Sendable () async throws -> Resource,
    operation: @Sendable (Resource) async throws -> Value
  ) async throws -> Value {
    let resource = try await makeResource()
    let value: Value
    do {
      value = try await operation(resource)
    } catch let operationError {
      var cleanupErrors: [String] = []
      do {
        try await resource.shutdownCredentials()
      } catch {
        cleanupErrors.append("credentials:\(String(reflecting: error))")
      }
      do {
        try await resource.shutdownTransport()
      } catch {
        cleanupErrors.append("transport:\(String(reflecting: error))")
      }
      guard cleanupErrors.isEmpty else {
        throw EvaluationWorkerLifecycleError.operationAndCleanupFailed(
          operation: String(reflecting: operationError),
          cleanup: cleanupErrors
        )
      }
      throw operationError
    }
    do {
      try await resource.shutdownCredentials()
    } catch {
      try? await resource.shutdownTransport()
      throw error
    }
    do {
      try await resource.shutdownTransport()
    } catch {
      throw error
    }
    return value
  }
}

enum EvaluationWorkerLifecycleError: Error, Sendable, Equatable {
  case operationAndCleanupFailed(operation: String, cleanup: [String])
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
    progressRecorder: EvaluationAttemptProgressRecorder? = nil
  ) async throws -> EvaluationLiveResource {
    let client = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: HTTPClientProfile.protectedEgress.configuration
    )
    let executor = AsyncHTTPExecutor(client: client)
    let recorder = EvaluationHTTPRecorder(
      base: executor,
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

    do {
      let stack = try ProviderStackFactory.make(
        route: route,
        settings: settings,
        loadStaticBearer: { nil },
        makeManagedCredentialStore: {
          EncryptedLLMCredentialStore(stateRoot: configuration.stateRootURL)
        },
        http: recorder,
        buildVersion: "swift-claw-evaluation-v1"
      )
      return EvaluationLiveResource(
        roster: ProviderRoster(primary: stack.binding),
        httpRecorder: recorder,
        credentialSource: stack.credentialSource,
        closeTransport: { try await client.shutdown() }
      )
    } catch {
      try? await client.shutdown()
      throw error
    }
  }
}

package struct EvaluationWorker: Sendable {
  package init() {}

  package func run(
    invocation: EvaluationWorkerInvocation,
    sealedOutputKey: Data? = nil
  ) async throws -> String {
    try await runResult(
      invocation: invocation,
      sealedOutputKey: sealedOutputKey,
      freezeVerifier: EvaluationLiveFreezeVerifier()
    ).attemptID
  }

  // swiftlint:disable:next function_body_length
  func runResult(
    invocation: EvaluationWorkerInvocation,
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
    let freeze = try await freezeVerifier.verifyLocal(invocation.freeze)
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
    else { throw EvaluationWorkerError.staleFailureEvidence }
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
        makeResource: {
          try await EvaluationLiveResourceFactory.make(
            configuration: configuration,
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
              await Self.liveAdmission(
                verifier: freezeVerifier,
                inputs: invocation.freeze,
                initial: freeze
              )
            }
          )
        }
      )
    }
    if configuration.requiresJointUnseal {
      guard let sealedOutputKey else { throw EvaluationWorkerError.sealedOutputKeyRequired }
      try EvaluationSealedResultStore.seal(
        result,
        keyData: sealedOutputKey,
        resultURL: configuration.resultURL
      )
    } else {
      guard sealedOutputKey == nil else { throw EvaluationWorkerError.unexpectedSealedOutputKey }
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
      else { throw EvaluationWorkerError.staleFailureEvidence }
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
                  await Self.liveAdmission(
                    verifier: freezeVerifier,
                    inputs: invocation.freeze,
                    initial: freeze
                  )
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

  private static func liveAdmission(
    verifier: any EvaluationFreezeVerifying,
    inputs: EvaluationFreezeInputs,
    initial: EvaluationFreezeContext
  ) async -> ProviderRoundTripAdmission {
    do {
      let refreshed = try await verifier.verifyLocal(inputs)
      guard refreshed.hasSameApprovedBinding(as: initial) else {
        return .deny(cap: "evaluation-freeze-integrity")
      }
      return .allow
    } catch {
      return .deny(cap: "evaluation-freeze-integrity")
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

enum EvaluationWorkerError: Error, Sendable, Equatable {
  case invalidCanaryProcessConfiguration
  case staleFailureEvidence
  case sealedOutputKeyRequired
  case unexpectedSealedOutputKey
}
