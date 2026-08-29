import ClawAgent
import ClawCore
import ClawSecrets
import ClawSubprocess
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
  }

  @Test func reflectorUsesTheFrozen768TokenReservation() async throws {
    // given
    let fixture = try makeLearningCallFixture(kind: .reflector)
    defer { fixture.remove() }
    let provider = SequenceProvider([fixture.response(content: "reflection")])

    // when
    let result = try await fixture.run(provider: provider)
    let request = try #require(await provider.requests.first)

    // then
    #expect(result.outcome == .response)
    #expect(request.maxOutputTokens == 768)
    #expect(result.maxOutputTokens == 768)
  }

  @Test(arguments: LearningCallOutputLimitCase.allCases)
  func outputOneUnitPastEitherFrozenLocalLimitFails(
    limitCase: LearningCallOutputLimitCase
  ) async throws {
    // given
    let fixture = try makeLearningCallFixture(route: limitCase.route)
    defer { fixture.remove() }
    let provider = SequenceProvider([fixture.response(content: limitCase.output)])

    // when
    let result = try await fixture.run(provider: provider)

    // then
    #expect(result.outcome == .failed)
    #expect(result.failureCode == EvaluationAttemptOutcome.localOutputLimit.rawValue)
    #expect(result.output == nil)
    #expect(result.usage?.responsesSends == 1)
    #expect(await provider.requests.count == 1)
  }

  @Test(arguments: LearningCallPreSendMutation.allCases)
  func everyFrozenPreSendBindingMustMatch(
    mutation: LearningCallPreSendMutation
  ) async throws {
    // given
    let fixture = try makeLearningCallFixture(route: mutation.route)
    defer { fixture.remove() }
    let provider = SequenceProvider([fixture.response(content: "unreachable")])

    // when
    let result = try await mutation.run(fixture: fixture, provider: provider)

    // then
    #expect(result.outcome == .failedNoCall)
    #expect(result.failureCode == EvaluationAttemptOutcome.harnessFailure.rawValue)
    #expect(result.usage == nil)
    #expect(await provider.requests.isEmpty)
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

  @Test func terminalModelAndUsageMustMatchTheFrozenRoute() async throws {
    // given
    let terminalMismatch = try makeLearningCallFixture()
    defer {
      terminalMismatch.remove()
    }
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
    let modelResult = try await terminalMismatch.run(provider: modelProvider)
    let usageResult = try await terminalMismatch.run(provider: overCapProvider)

    // then
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
      payload: Data("provider-state-secret".utf8)
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
    #expect(result.reportedModel == fixture.context.route.wireModel)
    #expect(result.usage?.responsesSends == 1)
    #expect(result.usage?.reportedTotalTokens == 16)
    #expect(result.usage?.accountedTokens == 16)
    #expect(result.usage?.isEstimated == false)
    #expect(result.provenance.requestSHA256 == fixture.requestSHA256)
    #expect(encodedText.contains("private-replay-state") == false)
    #expect(encodedText.contains(providerState.payload.base64EncodedString()) == false)
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

  @Test func oversizedTerminalToolArgumentsTakeLocalLimitPrecedence() async throws {
    // given
    let fixture = try makeLearningCallFixture(
      route: learningRoute(
        maxOutputTokens: 512,
        maxOutputUTF8Bytes: 8,
        maxOutputGraphemes: 8
      )
    )
    defer { fixture.remove() }
    let provider = SequenceProvider([
      fixture.response(
        content: "",
        toolCalls: [
          ToolCall(id: "call-1", name: "file_read", argumentsJSON: String(repeating: "x", count: 9))
        ]
      )
    ])

    // when
    let result = try await fixture.run(provider: provider)

    // then
    #expect(result.outcome == .failed)
    #expect(result.failureCode == EvaluationAttemptOutcome.localOutputLimit.rawValue)
    #expect(result.output == nil)
    #expect(result.usage?.responsesSends == 1)
    #expect(await provider.requests.count == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func managedProviderRetriesWithinTheFrozenBudgetAndCountsEverySend() async throws {
    // given
    let fixture = try makeLearningCallFixture()
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
      makeResource: { input in
        try await makeLearningResource(
          input: input,
          fixture: fixture,
          roster: ProviderRoster(primary: stack.binding),
          recorder: recorder,
          credentialSource: stack.credentialSource,
          closeTransport: {}
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

  @Test(.timeLimit(.minutes(1)))
  func managedConflictingTerminalEventsFailClosed() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let transport = ScriptedHTTPExecutor([
      .stream(
        HTTPStreamHead(statusCode: 200, headers: [:]),
        managedConflictingTerminalEvents()
      )
    ])
    let recorder = learningRecorder(fixture: fixture, transport: transport)
    let stack = try managedStack(fixture: fixture, recorder: recorder)

    // when
    let result = try await EvaluationLearningCall().run(
      request: fixture.request,
      makeResource: { input in
        try await makeLearningResource(
          input: input,
          fixture: fixture,
          roster: ProviderRoster(primary: stack.binding),
          recorder: recorder,
          credentialSource: stack.credentialSource,
          closeTransport: {}
        )
      }
    )

    // then
    #expect(result.outcome == .failed)
    #expect(result.failureCode == EvaluationAttemptOutcome.modelIdentityMismatch.rawValue)
    #expect(result.usage?.responsesSends == 1)
    #expect(await transport.recorded.count == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func exhaustedCleanManagedFailureMarksEverySendProvenNotStarted() async throws {
    // given
    let fixture = try makeLearningCallFixture()
    defer { fixture.remove() }
    let rejected = ScriptedHTTPExecutor.Step.stream(
      HTTPStreamHead(statusCode: 500, headers: [:]),
      [Data(#"{"error":{"message":"retry"}}"#.utf8)]
    )
    let transport = ScriptedHTTPExecutor([rejected, rejected, rejected])
    let recorder = learningRecorder(fixture: fixture, transport: transport)
    let stack = try managedStack(fixture: fixture, recorder: recorder)

    // when
    let result = try await EvaluationLearningCall().run(
      request: fixture.request,
      makeResource: { input in
        try await makeLearningResource(
          input: input,
          fixture: fixture,
          roster: ProviderRoster(primary: stack.binding),
          recorder: recorder,
          credentialSource: stack.credentialSource,
          closeTransport: {}
        )
      }
    )

    // then
    #expect(result.outcome == .failed)
    #expect(result.usage?.responsesSends == 3)
    #expect(result.usage?.provenNotStartedResponsesSends == 3)
    #expect(result.usage?.accountedTokens == 0)
    #expect(result.usage?.isEstimated == false)
    #expect(await transport.recorded.count == 3)
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

// MARK: - Fixture

enum LearningCallOutputLimitCase: CaseIterable, Sendable {
  case utf8
  case grapheme

  var route: EvaluationLearningRouteBinding {
    switch self {
    case .utf8:
      learningRoute(maxOutputTokens: 512, maxOutputUTF8Bytes: 4, maxOutputGraphemes: 10)
    case .grapheme:
      learningRoute(maxOutputTokens: 512, maxOutputUTF8Bytes: 10, maxOutputGraphemes: 4)
    }
  }

  var output: String { "abcde" }
}

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

enum LearningCallPreSendMutation: CaseIterable, Sendable {
  case configuredReference
  case wireModel
  case retryBudget
  case outputCap
  case costPolicy
  case reservationPolicy
  case requestDigest
  case promptDigest
  case carrierDigest

  var route: EvaluationLearningRouteBinding {
    switch self {
    case .retryBudget:
      learningRoute(maxOutputTokens: 512, retryBudget: 2)
    case .outputCap:
      learningRoute(maxOutputTokens: 768)
    default:
      learningRoute(maxOutputTokens: 512)
    }
  }

  fileprivate func run(
    fixture: LearningCallFixture,
    provider: SequenceProvider
  ) async throws -> EvaluationLearningCallResult {
    let binding: LLMRouteBinding
    switch self {
    case .configuredReference:
      binding = fixture.binding(provider: provider, configuredReference: "changed/reference")
    case .wireModel:
      binding = fixture.binding(provider: provider, wireModel: "changed-model")
    case .costPolicy:
      binding = fixture.binding(provider: provider, costPolicy: .metered)
    case .reservationPolicy:
      binding = fixture.binding(provider: provider, reservationPolicy: .textOnly)
    default:
      binding = fixture.binding(provider: provider)
    }
    return try await fixture.run(
      binding: binding,
      requestSHA256: self == .requestDigest ? String(repeating: "f", count: 64) : nil,
      prompt: self == .promptDigest ? "changed prompt" : nil,
      carrier: self == .carrierDigest ? "changed carrier" : nil,
      liveAdmission: { .allow }
    )
  }
}

private struct LearningCallFixture: Sendable {
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
private func makeLearningCallFixture(
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

private func learningRoute(
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

private func learningRecorder(
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

private func managedStack(
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
private func makeLearningResource(
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

private func learningResource(
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

private func managedConflictingTerminalEvents() -> [Data] {
  managedSuccessEvents() + [
    responsesEvent(
      #"{"type":"response.done","response":{"id":"resp_1","status":"completed","model":"conflicting-model","usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}"#
    )
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
