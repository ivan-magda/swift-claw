import ClawAgent
import ClawCore
import ClawSecrets
import ClawSubprocess
import ClawTestSupport
import Foundation
import Testing

@testable import ClawEvaluation
@testable import ClawLLM

@Suite struct EvaluationLearningCallTests {
  @Test func productionLearningCompositionUsesExternalEncryptedCredentials() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let credentialRoot = try makeEvaluationCredentialStateRoot(under: fixture.root)
    let transport = ScriptedHTTPExecutor([])
    let input = EvaluationLearningCallResourceFactoryInput(
      request: fixture.request,
      requestSHA256: fixture.requestSHA256,
      credentialStateRoot: credentialRoot
    )

    // when
    let resource = try await EvaluationLearningCall.makeLiveResource(
      input: input,
      admissionVerifier: fixture.admissionVerifier,
      http: transport,
      closeTransport: {}
    )
    try await resource.shutdownCredentials()
    try await resource.shutdownTransport()

    // then — the private M3 call state has no encrypted credential material.
    #expect(await transport.recorded.isEmpty)
  }

  @Test func unsafeCredentialRootStopsBeforeLearningResourceConstruction() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let construction = LearningCallConstructionCounter()

    // when
    let error = await #expect(
      throws: EvaluationCredentialStateRootError.evaluationStateForbidden
    ) {
      _ = try await EvaluationLearningCall().run(
        request: fixture.request,
        credentialStateRoot: fixture.stateRoot.path,
        makeResource: { _ in
          await construction.increment()
          throw LearningCallConstructionSentinel.entered
        }
      )
    }

    // then
    #expect(error != nil)
    #expect(await construction.value == 0)
  }

  @Test func heldCredentialLockStopsBeforeLearningResourceConstruction() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let credentialRoot = try makeEvaluationCredentialStateRoot(under: fixture.root)
    let lock = try InstanceLock(path: SecretStatePaths(stateRoot: credentialRoot).instanceLock.path)
    defer { lock.release() }
    let construction = LearningCallConstructionCounter()

    // when
    let error = await #expect(throws: InstanceLock.LockError.alreadyLocked) {
      _ = try await EvaluationLearningCall().run(
        request: fixture.request,
        credentialStateRoot: credentialRoot.path,
        makeResource: { _ in
          await construction.increment()
          throw LearningCallConstructionSentinel.entered
        }
      )
    }

    // then
    #expect(error != nil)
    #expect(await construction.value == 0)
  }

  @Test func productionSelectsArgumentZeroBeforeMissingCredentialFailure() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let decoyRoot = fixture.root.appendingPathComponent(
      "Decoy.bundle/Contents/MacOS",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: decoyRoot, withIntermediateDirectories: true)
    let decoyExecutableURL = decoyRoot.appendingPathComponent("claw-eval-decoy")
    try Data("decoy executable".utf8).write(to: decoyExecutableURL)
    for executableURL in [fixture.executableURL, decoyExecutableURL] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executableURL.path
      )
    }

    // when
    let result = try await EvaluationLearningCall().run(
      request: fixture.request,
      credentialStateRoot: fixture.root.path,
      makeResource: EvaluationLearningCall.productionResourceFactory(
        arguments: [fixture.executableURL.path, decoyExecutableURL.path]
      )
    )
    let durable = try fixture.readDurableResult()
    let lockIsFree = try EvaluationWorkerLifecycle.proveProductionLockIsFree(
      stateRoot: fixture.stateRoot
    )

    // then
    #expect(result == durable)
    #expect(result.outcome == .failed)
    #expect(result.failureCode == EvaluationAttemptOutcome.authenticationRequired.rawValue)
    #expect(result.usage?.responsesSends == 0)
    #expect(result.usage?.provenNotStartedResponsesSends == 0)
    #expect(result.usage?.accountedTokens == 0)
    #expect(result.usage?.isEstimated == false)
    #expect(lockIsFree)
  }

  @Test func liveAdmissionDenialPublishesFailedNoCallAndCleansUp() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let provider = SequenceProvider([fixture.response(content: "unreachable")])
    let lifecycle = LearningCallLifecycleProbe()
    let recorder = learningRecorder(fixture: fixture)

    // when
    let result = try await EvaluationLearningCall().run(
      request: fixture.request,
      credentialStateRoot: fixture.root.path,
      makeResource: { input in
        try await makeLearningResource(
          input: input,
          fixture: fixture,
          roster: ProviderRoster(primary: fixture.binding(provider: provider)),
          recorder: recorder,
          credentialSource: LearningCallCredentialSource(lifecycle: lifecycle),
          closeTransport: {
            await lifecycle.recordTransportShutdown()
          },
          liveAdmission: { ProviderRoundTripAdmission.deny(cap: "test-live-denial") }
        )
      }
    )
    let durable = try fixture.readDurableResult()
    let lockIsFree = try EvaluationWorkerLifecycle.proveProductionLockIsFree(
      stateRoot: fixture.stateRoot
    )

    // then
    #expect(result == durable)
    #expect(result.outcome == .failedNoCall)
    #expect(result.usage == nil)
    #expect(await provider.requests.isEmpty)
    #expect(await lifecycle.credentialShutdownCount == 1)
    #expect(await lifecycle.transportShutdownCount == 1)
    #expect(lockIsFree)
  }

  @Test func liveAdmissionDenialRejectsAnObservedResponsesSend() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let provider = SequenceProvider([fixture.response(content: "unreachable")])
    let lifecycle = LearningCallLifecycleProbe()
    let recorder = learningRecorder(fixture: fixture)

    // when
    await #expect(throws: EvaluationLearningAdmissionError.integrityFailure) {
      try await EvaluationLearningCall().run(
        request: fixture.request,
        credentialStateRoot: fixture.root.path,
        makeResource: { input in
          try await makeLearningResource(
            input: input,
            fixture: fixture,
            roster: ProviderRoster(primary: fixture.binding(provider: provider)),
            recorder: recorder,
            credentialSource: LearningCallCredentialSource(lifecycle: lifecycle),
            closeTransport: {
              await lifecycle.recordTransportShutdown()
            },
            liveAdmission: { ProviderRoundTripAdmission.deny(cap: "test-live-denial") },
            recordResponsesSend: true
          )
        }
      )
    }

    // then
    #expect(FileManager.default.fileExists(atPath: fixture.resultURL.path) == false)
    #expect(await provider.requests.isEmpty)
    #expect(await lifecycle.credentialShutdownCount == 1)
    #expect(await lifecycle.transportShutdownCount == 1)
    #expect(try EvaluationWorkerLifecycle.proveProductionLockIsFree(stateRoot: fixture.stateRoot))
  }

  @Test(arguments: LearningCallLiveArtifactMutation.allCases)
  func liveReadmissionRejectsArtifactMutationInsideResourceFactory(
    _ mutation: LearningCallLiveArtifactMutation
  ) async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let provider = SequenceProvider([fixture.response(content: "unreachable")])
    let lifecycle = LearningCallLifecycleProbe()
    let recorder = learningRecorder(fixture: fixture)

    // when
    let result = try await EvaluationLearningCall().run(
      request: fixture.request,
      credentialStateRoot: fixture.root.path,
      makeResource: { input in
        let admission = try await input.admission(using: fixture.admissionVerifier)
        try mutation.apply(to: fixture.request)
        return learningResource(
          admission: admission,
          roster: ProviderRoster(primary: fixture.binding(provider: provider)),
          recorder: recorder,
          credentialSource: LearningCallCredentialSource(lifecycle: lifecycle),
          closeTransport: {
            await lifecycle.recordTransportShutdown()
          }
        )
      }
    )

    // then
    #expect(result.outcome == .failedNoCall)
    #expect(result.usage == nil)
    #expect(await provider.requests.isEmpty)
    #expect(await lifecycle.credentialShutdownCount == 1)
    #expect(await lifecycle.transportShutdownCount == 1)
    #expect(try fixture.readDurableResult() == result)
  }

  @Test func resourceFactoryRunsWhileProductionLockIsHeld() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let provider = SequenceProvider([fixture.response(content: "ok")])
    let lifecycle = LearningCallLifecycleProbe()
    let recorder = learningRecorder(fixture: fixture)

    // when
    let result = try await EvaluationLearningCall().run(
      request: fixture.request,
      credentialStateRoot: fixture.root.path,
      makeResource: { input in
        let lockPath = SecretStatePaths(stateRoot: fixture.stateRoot).instanceLock.path
        do {
          let unexpected = try InstanceLock(path: lockPath)
          unexpected.release()
        } catch InstanceLock.LockError.alreadyLocked {
          await lifecycle.recordLockContention()
        }
        return try await makeLearningResource(
          input: input,
          fixture: fixture,
          roster: ProviderRoster(primary: fixture.binding(provider: provider)),
          recorder: recorder,
          credentialSource: LearningCallCredentialSource(lifecycle: lifecycle),
          closeTransport: {
            await lifecycle.recordTransportShutdown()
          },
          recordResponsesSend: true
        )
      }
    )

    // then
    #expect(result.outcome == .response)
    #expect(await lifecycle.lockContentionCount == 1)
    #expect(try EvaluationWorkerLifecycle.proveProductionLockIsFree(stateRoot: fixture.stateRoot))
  }

  @Test func exclusivePublicationDoesNotReplaceExistingResultAndStillCleansUp() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let existing = Data("existing-result".utf8)
    try existing.write(to: fixture.resultURL)
    let provider = SequenceProvider([fixture.response(content: "unused")])
    let lifecycle = LearningCallLifecycleProbe()
    let recorder = learningRecorder(fixture: fixture)

    // when
    await #expect(throws: (any Error).self) {
      try await EvaluationLearningCall().run(
        request: fixture.request,
        credentialStateRoot: fixture.root.path,
        makeResource: { input in
          try await makeLearningResource(
            input: input,
            fixture: fixture,
            roster: ProviderRoster(primary: fixture.binding(provider: provider)),
            recorder: recorder,
            credentialSource: LearningCallCredentialSource(lifecycle: lifecycle),
            closeTransport: {
              await lifecycle.recordTransportShutdown()
            },
            recordResponsesSend: true
          )
        }
      )
    }
    let retained = try Data(contentsOf: fixture.resultURL)

    // then
    #expect(retained == existing)
    #expect(await lifecycle.credentialShutdownCount == 1)
    #expect(await lifecycle.transportShutdownCount == 1)
    #expect(try EvaluationWorkerLifecycle.proveProductionLockIsFree(stateRoot: fixture.stateRoot))
  }

  @Test func liveCompositionVerifiesPublishesAndCleansUp() async throws {
    // given
    let fixture = try makeLearningCallFixture()
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
      credentialStateRoot: fixture.root.path,
      makeResource: { input in
        let admission = try await input.admission(using: fixture.admissionVerifier)
        await lifecycle.recordStartupAdmission(admission.context)
        let exchange = try await recorder.openStream(
          responsesRequest(wireModel: admission.context.route.wireModel)
        )
        _ = await exchange.cancelAndAwait()
        return EvaluationLearningCallResource(
          admission: admission,
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

private actor LearningCallConstructionCounter {
  private(set) var value = 0

  func increment() {
    value += 1
  }
}

private enum LearningCallConstructionSentinel: Error {
  case entered
}

// MARK: - Fixture

enum LearningCallLiveArtifactMutation: CaseIterable, Sendable {
  case prompt
  case carrier

  func apply(to request: EvaluationLearningCallRequest) throws {
    let path =
      switch self {
      case .prompt: request.prompt.path
      case .carrier: request.carrier.path
      }
    try Data("changed \(self)".utf8).write(to: URL(fileURLWithPath: path))
  }
}

// MARK: - Lifecycle

actor LearningCallLifecycleProbe {
  private(set) var startupAdmission: EvaluationLearningAdmissionContext?
  private(set) var credentialShutdownCount = 0
  private(set) var transportShutdownCount = 0
  private(set) var lockContentionCount = 0

  func recordStartupAdmission(_ context: EvaluationLearningAdmissionContext) {
    startupAdmission = context
  }

  func recordCredentialShutdown() {
    credentialShutdownCount += 1
  }

  func recordTransportShutdown() {
    transportShutdownCount += 1
  }

  func recordLockContention() {
    lockContentionCount += 1
  }
}

struct LearningCallCredentialSource: LLMCredentialSource {
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
