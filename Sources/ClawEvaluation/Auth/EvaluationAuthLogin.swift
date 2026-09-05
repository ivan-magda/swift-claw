import AsyncHTTPClient
import ClawAuth
import ClawCore
import ClawHTTP
import ClawSecrets
import ClawSubprocess
import Foundation

/// The four owner-supplied bindings required before the evaluation executable may start a device
/// authorization. None of them has an ambient default: a login cannot silently inherit the
/// production daemon's state root, model, configuration, or approval inputs.
package struct EvaluationAuthLoginRequest: Sendable, Equatable {
  package let freeze: EvaluationFreezeInputs
  package let runtimeConfigurationPath: String
  package let evaluationRoot: String
  package let wireModel: String

  package init(
    freeze: EvaluationFreezeInputs,
    runtimeConfigurationPath: String,
    evaluationRoot: String,
    wireModel: String
  ) {
    self.freeze = freeze
    self.runtimeConfigurationPath = runtimeConfigurationPath
    self.evaluationRoot = evaluationRoot
    self.wireModel = wireModel
  }
}

/// A device login exposed only after the supplied runtime and D6 approval agree. The injected
/// initializer is internal so tests can
/// prove failures stop before the egress-capable continuation without creating a real HTTP client.
package struct EvaluationAuthLogin: Sendable {
  typealias AuthorizedLogin = @Sendable (Authorization) async -> AuthCommandResult

  struct Authorization: Sendable {
    let request: EvaluationAuthLoginRequest
    let freeze: EvaluationFreezeContext
    let runtime: EvaluationRuntimeConfiguration

    var stateRootURL: URL {
      runtime.evaluationRootURL.appendingPathComponent(PageEvaluationContract.stateDirectoryName)
    }
  }

  private let freezeVerifier: any EvaluationFreezeVerifying
  private let performAuthorizedLogin: AuthorizedLogin

  package init() {
    let verifier = EvaluationLiveFreezeVerifier()
    freezeVerifier = verifier
    performAuthorizedLogin = { authorization in
      await Self.performLiveLogin(
        authorization: authorization,
        freezeVerifier: verifier
      )
    }
  }

  init(
    freezeVerifier: any EvaluationFreezeVerifying,
    performAuthorizedLogin: @escaping AuthorizedLogin
  ) {
    self.freezeVerifier = freezeVerifier
    self.performAuthorizedLogin = performAuthorizedLogin
  }

  package func run(_ request: EvaluationAuthLoginRequest) async throws -> AuthCommandResult {
    let authorization = try await authorize(request)
    return await performAuthorizedLogin(authorization)
  }
}

// MARK: - Pre-egress authorization

private extension EvaluationAuthLogin {
  func authorize(_ request: EvaluationAuthLoginRequest) async throws -> Authorization {
    guard
      request.runtimeConfigurationPath.hasPrefix("/"),
      request.evaluationRoot.hasPrefix("/"),
      request.freeze.repositoryRoot.hasPrefix("/"),
      request.freeze.manifestPath.hasPrefix("/"),
      request.freeze.approvalRecordPath.hasPrefix("/"),
      request.freeze.approvalBodyPath.hasPrefix("/"),
      request.freeze.runtimeConfigurationPath.hasPrefix("/"),
      request.freeze.receiptPath.hasPrefix("/")
    else {
      throw EvaluationAuthLoginError.pathsMustBeAbsolute
    }
    guard request.runtimeConfigurationPath == request.freeze.runtimeConfigurationPath else {
      throw EvaluationAuthLoginError.runtimeConfigurationPathMismatch
    }

    let rawRuntimeURL = URL(fileURLWithPath: request.runtimeConfigurationPath)
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [rawRuntimeURL])
    let runtimeURL = rawRuntimeURL.standardizedFileURL
    let runtime = try EvaluationRuntimeConfiguration.load(from: runtimeURL)
    guard request.evaluationRoot == runtime.evaluationRoot else {
      throw EvaluationAuthLoginError.evaluationRootMismatch
    }
    guard
      request.wireModel == PageEvaluationContract.wireModel,
      request.wireModel == runtime.wireModel,
      runtime.providerReference == PageEvaluationContract.providerReference
    else {
      throw EvaluationAuthLoginError.wireModelMismatch
    }

    let evaluationRoot = runtime.evaluationRootURL.standardizedFileURL
    let stateRoot = evaluationRoot.appendingPathComponent(PageEvaluationContract.stateDirectoryName)
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [evaluationRoot, stateRoot])

    let verified = try await freezeVerifier.verify(request.freeze)
    let verifiedRepositoryRoot = URL(
      fileURLWithPath: verified.repositoryRoot,
      isDirectory: true
    ).standardizedFileURL
    let requestedRepositoryRoot = URL(
      fileURLWithPath: request.freeze.repositoryRoot,
      isDirectory: true
    ).standardizedFileURL
    guard
      verified.runtime == runtime,
      verifiedRepositoryRoot == requestedRepositoryRoot
    else {
      throw EvaluationAuthLoginError.freezeBindingMismatch
    }
    return Authorization(request: request, freeze: verified, runtime: runtime)
  }
}

// MARK: - Live composition

private extension EvaluationAuthLogin {
  static func performLiveLogin(
    authorization: Authorization,
    freezeVerifier: any EvaluationFreezeVerifying
  ) async -> AuthCommandResult {
    let client = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: HTTPClientProfile.protectedEgress.configuration
    )
    let executor = AsyncHTTPExecutor(client: client)
    let oauth = ChatGPTOAuthClient(http: executor, wallDate: { Date() })
    let deviceAuthorization = EvaluationIntegrityGatedDeviceAuthorization(
      base: ChatGPTDeviceAuthorization(client: oauth, clock: ContinuousClock()),
      freezeVerifier: freezeVerifier,
      freezeInputs: authorization.request.freeze,
      initialFreeze: authorization.freeze
    )
    let stateRoot = authorization.stateRootURL
    let workflow = AuthLoginWorkflow(
      bootstrap: AuthBootstrap(
        stateRoot: stateRoot,
        configuredModel: authorization.runtime.providerReference
      ),
      runtimeSecrets: EvaluationAuthRuntimeSecretPreparer(stateRoot: stateRoot),
      mutationLock: EvaluationAuthMutationLock(stateRoot: stateRoot),
      makeCredentialStore: { EncryptedLLMCredentialStore(stateRoot: stateRoot) },
      makeDeviceAuthorization: { deviceAuthorization },
      tokenExchange: oauth,
      catalog: EvaluationFrozenModelCatalog(wireModel: authorization.runtime.wireModel),
      terminal: EvaluationAuthTerminal(),
      profileID: { UUID() }
    )
    let result = await workflow.login()
    // The workflow has already classified and presented its own outcome. Transport teardown cannot
    // make a completed grant un-happen, and mirrors the production auth command's lifecycle rule.
    try? await client.shutdown()
    return result
  }
}

/// The last integrity barrier is inside the device-authorizing seam itself. Runtime-secret sealing
/// and lock acquisition therefore cannot create a time-of-check shortcut around D6: immediately
/// before the first OAuth request, the approval/executable binding is checked again.
struct EvaluationIntegrityGatedDeviceAuthorization<Base: ChatGPTDeviceAuthorizing>:
  ChatGPTDeviceAuthorizing
{
  let base: Base
  let freezeVerifier: any EvaluationFreezeVerifying
  let freezeInputs: EvaluationFreezeInputs
  let initialFreeze: EvaluationFreezeContext

  func authorize(
    onDeviceCode: @escaping @Sendable (ChatGPTDeviceCode) async -> Void
  ) async throws -> ChatGPTAuthorizationGrant {
    let refreshed = try await freezeVerifier.verifyLocal(freezeInputs)
    guard refreshed.hasSameApprovedBinding(as: initialFreeze) else {
      throw EvaluationAuthLoginError.freezeBindingChanged
    }
    return try await base.authorize(onDeviceCode: onDeviceCode)
  }
}

/// `AuthLoginWorkflow` shares the daemon's encrypted secret backend, which requires a runtime
/// envelope before it can save the OAuth credential. This one fixed, non-routable value exists only
/// to initialize that encryption key; no process environment is read or copied.
struct EvaluationAuthRuntimeSecretPreparer: AuthRuntimeSecretPreparing {
  static let syntheticTelegramSecret = "evaluation-only-unused-telegram-secret"
  static let isolatedEnvironment = [
    EnvSecretStore.EnvKey.botToken: syntheticTelegramSecret
  ]
  static let isolatedSecrets = Secrets(
    telegramBotToken: syntheticTelegramSecret,
    llmApiKey: nil,
    searchApiKey: nil,
    llmFallbackApiKey: nil
  )

  let stateRoot: URL

  func prepare() throws {
    let prepared = try RuntimeSecretPreparer.prepare(
      stateRoot: stateRoot,
      environment: Self.isolatedEnvironment
    )
    guard prepared == Self.isolatedSecrets else {
      throw EvaluationAuthLoginError.nonSyntheticRuntimeSecrets
    }
  }
}

struct EvaluationAuthMutationLock: AuthMutationLocking {
  let stateRoot: URL

  func acquire() throws -> AuthMutationLease {
    do {
      try EvaluationPathSecurity.ensurePrivateDirectory(at: stateRoot)
      let lock = try InstanceLock(path: SecretStatePaths(stateRoot: stateRoot).instanceLock.path)
      return AuthMutationLease { lock.release() }
    } catch InstanceLock.LockError.alreadyLocked {
      throw AuthMutationLockFailure.held
    } catch let failure as AuthMutationLockFailure {
      throw failure
    } catch {
      throw AuthMutationLockFailure.unavailable(detail: String(reflecting: error))
    }
  }
}

/// The evaluation login never performs catalog discovery and never offers a model picker. The
/// credential is stored for the one wire model already frozen by D6; entitlement is still checked
/// by the normal provider path when a scored attempt is eventually authorized.
struct EvaluationFrozenModelCatalog: ChatGPTModelCatalogFetching {
  let wireModel: String

  func fetch(authorization: LLMRequestAuthorization) async throws -> [ChatGPTCatalogModel] {
    [ChatGPTCatalogModel(slug: wireModel, priority: 0)]
  }
}

/// Device-code output is interactive, model selection is not. Returning `false` prevents the
/// production workflow from accepting terminal input that could choose a model other than D6.
struct EvaluationAuthTerminal: AuthTerminal {
  let isInteractive = false

  func readLine() async throws -> String? { nil }

  func write(_ event: AuthPresentationEvent) async {
    let data = Data("\(event.text)\n".utf8)
    switch event.destination {
    case .standardOutput:
      FileHandle.standardOutput.write(data)
    case .standardError:
      FileHandle.standardError.write(data)
    }
  }
}

enum EvaluationAuthLoginError: Error, Sendable, Equatable {
  case pathsMustBeAbsolute
  case runtimeConfigurationPathMismatch
  case evaluationRootMismatch
  case wireModelMismatch
  case freezeBindingMismatch
  case freezeBindingChanged
  case nonSyntheticRuntimeSecrets
}
