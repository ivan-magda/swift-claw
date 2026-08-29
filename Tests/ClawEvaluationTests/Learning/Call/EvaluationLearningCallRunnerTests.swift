import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawEvaluation
@testable import ClawLLM

@Suite struct EvaluationLearningCallRunnerTests {
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
