import ClawAuth
import ClawCore
import ClawSecrets
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationAuthLoginTests {
  @Test func approvedInputsReachOnlyTheEvaluationStateRootAndFrozenModel() async throws {
    // given
    let fixture = try makeAuthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = AuthorizedLoginRecorder()
    let freezeVerifier = ModeRecordingFreezeVerifier(
      context: fixture.freeze.context,
      refuseLocal: false
    )
    let login = EvaluationAuthLogin(
      freezeVerifier: freezeVerifier,
      performAuthorizedLogin: { authorization in
        await recorder.perform(authorization)
      }
    )

    // when
    let result = try await login.run(fixture.request)

    // then
    #expect(result.exit == .success)
    #expect(await recorder.callCount == 1)
    #expect(await freezeVerifier.liveCalls == 1)
    #expect(await freezeVerifier.localCalls == 0)
    #expect(
      await recorder.stateRootPath
        == fixture.configuration.stateRootURL.standardizedFileURL.path
    )
    #expect(await recorder.wireModel == PageEvaluationContract.wireModel)
  }

  @Test
  func arbitraryRuntimePathRootOrModelNeverReachesTheEgressCapableContinuation() async throws {
    // given
    let fixture = try makeAuthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = AuthorizedLoginRecorder()
    let login = EvaluationAuthLogin(
      freezeVerifier: StaticEvaluationFreezeVerifier(context: fixture.freeze.context),
      performAuthorizedLogin: { authorization in
        await recorder.perform(authorization)
      }
    )
    let unrelatedRuntime = fixture.root.appendingPathComponent("unapproved-runtime.json")
    try Data(contentsOf: URL(fileURLWithPath: fixture.request.runtimeConfigurationPath))
      .write(to: unrelatedRuntime)
    let mutants = [
      EvaluationAuthLoginRequest(
        freeze: fixture.freeze.inputs,
        runtimeConfigurationPath: unrelatedRuntime.path,
        evaluationRoot: fixture.request.evaluationRoot,
        wireModel: fixture.request.wireModel
      ),
      EvaluationAuthLoginRequest(
        freeze: fixture.freeze.inputs,
        runtimeConfigurationPath: fixture.request.runtimeConfigurationPath,
        evaluationRoot: fixture.root.appendingPathComponent("production-lookalike").path,
        wireModel: fixture.request.wireModel
      ),
      EvaluationAuthLoginRequest(
        freeze: fixture.freeze.inputs,
        runtimeConfigurationPath: fixture.request.runtimeConfigurationPath,
        evaluationRoot: fixture.request.evaluationRoot,
        wireModel: "gpt-5.6-terra"
      ),
    ]

    // when
    var errors: [EvaluationAuthLoginError?] = []
    for mutant in mutants {
      let error = await #expect(throws: EvaluationAuthLoginError.self) {
        _ = try await login.run(mutant)
      }
      errors.append(error)
    }

    // then
    #expect(errors.count == mutants.count)
    #expect(errors.allSatisfy { $0 != nil })
    #expect(await recorder.callCount == 0)
  }

  @Test func rawRuntimeDotComponentIsRejectedBeforeFreezeOrEgressAuthorization() async throws {
    // given
    let fixture = try makeAuthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let runtime = URL(fileURLWithPath: fixture.request.runtimeConfigurationPath)
    let rawRuntime = runtime.deletingLastPathComponent().path + "/./" + runtime.lastPathComponent
    let freezeInputs = EvaluationFreezeInputs(
      repositoryRoot: fixture.freeze.inputs.repositoryRoot,
      manifestPath: fixture.freeze.inputs.manifestPath,
      manifestSHA256: fixture.freeze.inputs.manifestSHA256,
      approvalRecordPath: fixture.freeze.inputs.approvalRecordPath,
      approvalBodyPath: fixture.freeze.inputs.approvalBodyPath,
      runtimeConfigurationPath: rawRuntime,
      receiptPath: fixture.freeze.inputs.receiptPath
    )
    let verifier = ModeRecordingFreezeVerifier(
      context: fixture.freeze.context,
      refuseLocal: false
    )
    let recorder = AuthorizedLoginRecorder()
    let login = EvaluationAuthLogin(
      freezeVerifier: verifier,
      performAuthorizedLogin: { authorization in
        await recorder.perform(authorization)
      }
    )
    let request = EvaluationAuthLoginRequest(
      freeze: freezeInputs,
      runtimeConfigurationPath: rawRuntime,
      evaluationRoot: fixture.request.evaluationRoot,
      wireModel: fixture.request.wireModel
    )

    // when
    let error = await #expect(throws: EvaluationPathSecurityError.dotPathComponent(".")) {
      _ = try await login.run(request)
    }

    // then
    #expect(error != nil)
    #expect(await verifier.liveCalls == 0)
    #expect(await recorder.callCount == 0)
  }

  @Test func finalFreezeRecheckIsLocalAndMakesZeroDeviceAuthorizationCallsOnFailure() async throws {
    // given
    let fixture = try makeAuthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let device = RecordingDeviceAuthorizer()
    let freezeVerifier = ModeRecordingFreezeVerifier(context: fixture.freeze.context)
    let gated = EvaluationIntegrityGatedDeviceAuthorization(
      base: device,
      freezeVerifier: freezeVerifier,
      freezeInputs: fixture.freeze.inputs,
      initialFreeze: fixture.freeze.context
    )

    // when
    let error = await #expect(throws: AuthFreezeTestError.refused) {
      _ = try await gated.authorize(onDeviceCode: { _ in })
    }

    // then
    #expect(error != nil)
    #expect(await device.callCount == 0)
    #expect(await freezeVerifier.liveCalls == 0)
    #expect(await freezeVerifier.localCalls == 1)
  }

  @Test func runtimeSecretBootstrapPersistsOnlyTheIsolatedSecrets() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    try EvaluationPathSecurity.ensurePrivateDirectory(at: stateRoot)
    let preparer = EvaluationAuthRuntimeSecretPreparer(stateRoot: stateRoot)

    // when
    try preparer.prepare()
    let persisted = try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets()

    // then
    #expect(persisted == EvaluationAuthRuntimeSecretPreparer.isolatedSecrets)
  }

  @Test func preexistingForeignRuntimeSecretsAreRefusedRatherThanReadIntoEvaluation() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    _ = try EncryptedFileSecretStore.seal(
      Secrets(
        telegramBotToken: "production-looking-token",
        llmApiKey: "production-looking-api-key"
      ),
      stateRoot: stateRoot
    )

    // when
    let error = #expect(throws: EvaluationAuthLoginError.nonSyntheticRuntimeSecrets) {
      try EvaluationAuthRuntimeSecretPreparer(stateRoot: stateRoot).prepare()
    }

    // then
    #expect(error != nil)
  }
}

private struct AuthFixture {
  let root: URL
  let configuration: EvaluationAttemptConfiguration
  let freeze: (inputs: EvaluationFreezeInputs, context: EvaluationFreezeContext, executable: URL)
  let request: EvaluationAuthLoginRequest
}

private func makeAuthFixture() throws -> AuthFixture {
  let root = try makeEvaluationTestRoot()
  let configured = try makeEvaluationConfiguration(root: root)
  let freeze = try makeEvaluationFreeze(
    root: root,
    configurations: [configured.configuration]
  )
  let request = EvaluationAuthLoginRequest(
    freeze: freeze.inputs,
    runtimeConfigurationPath: freeze.inputs.runtimeConfigurationPath,
    evaluationRoot: configured.configuration.evaluationRoot,
    wireModel: PageEvaluationContract.wireModel
  )
  return AuthFixture(
    root: root,
    configuration: configured.configuration,
    freeze: freeze,
    request: request
  )
}

private actor AuthorizedLoginRecorder {
  private(set) var callCount = 0
  private(set) var stateRootPath: String?
  private(set) var wireModel: String?

  func perform(_ authorization: EvaluationAuthLogin.Authorization) -> AuthCommandResult {
    callCount += 1
    stateRootPath = authorization.stateRootURL.standardizedFileURL.path
    wireModel = authorization.runtime.wireModel
    return AuthCommandResult(exit: .success, events: [])
  }
}

private actor RecordingDeviceAuthorizer: ChatGPTDeviceAuthorizing {
  private(set) var callCount = 0

  func authorize(
    onDeviceCode: @escaping @Sendable (ChatGPTDeviceCode) async -> Void
  ) async throws -> ChatGPTAuthorizationGrant {
    callCount += 1
    return ChatGPTAuthorizationGrant(authorizationCode: "unused", codeVerifier: "unused")
  }
}

private enum AuthFreezeTestError: Error {
  case refused
}

private actor ModeRecordingFreezeVerifier: EvaluationFreezeVerifying {
  let context: EvaluationFreezeContext
  let refuseLocal: Bool
  private(set) var liveCalls = 0
  private(set) var localCalls = 0

  init(context: EvaluationFreezeContext, refuseLocal: Bool = true) {
    self.context = context
    self.refuseLocal = refuseLocal
  }

  func verify(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    liveCalls += 1
    return context
  }

  func verifyLocal(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    localCalls += 1
    if refuseLocal { throw AuthFreezeTestError.refused }
    return context
  }
}
