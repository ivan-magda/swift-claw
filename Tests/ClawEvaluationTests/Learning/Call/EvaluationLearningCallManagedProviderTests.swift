import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawEvaluation
@testable import ClawLLM

@Suite struct EvaluationLearningCallManagedProviderTests {
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
}
