import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct ConferenceSubmissionJudgeTests {
  @Test(arguments: ["SAFE", "UNSAFE", "safe", "SAFE because I said so", "{\"safe\":true}"])
  func onlyAnExplicitSafeVerdictPasses(_ verdict: String) async throws {
    // given
    let provider = ConferenceJudgeProvider(verdict: verdict)
    let judge = ConferenceSubmissionJudge(provider: provider, model: "fixture-model")
    let proposal = PreparedConferenceSubmission(
      caseSnapshot: ConferenceWorkflowFixture.item,
      answer: "Restore VoiceOver labels and add regression tests."
    )

    // when
    var accepted = false
    do {
      try await judge.check(proposal)
      accepted = true
    } catch ConferenceError.invalidAnswer {
      // An unsafe or malformed response must not admit Coder.
    }

    // then
    #expect(accepted == (verdict == "SAFE"))
    let request = try #require(await provider.request)
    #expect(request.tools.isEmpty)
    #expect(request.maxOutputTokens == 2_048)
    #expect(request.messages.count == 2)
    #expect(request.messages[0].role == .system)
    #expect(request.messages[1].role == .user)
  }

  @Test func providerFailureDoesNotAdmitOrExposeDiagnostics() async throws {
    // given
    let judge = ConferenceSubmissionJudge(
      provider: ConferenceJudgeProvider(verdict: "SAFE", fail: true),
      model: "fixture-model"
    )

    // when / then
    do {
      try await judge.check(
        PreparedConferenceSubmission(
          caseSnapshot: ConferenceWorkflowFixture.item,
          answer: "Use an actor."
        )
      )
      Issue.record("A failed judge request was accepted")
    } catch ConferenceError.invalidAnswer(let message) {
      #expect(message.contains("unavailable"))
      #expect(!message.contains("private-provider-diagnostic"))
    }
  }

  @Test func timeoutCancelsAndJoinsProviderWork() async throws {
    // given
    let provider = ConferenceJudgeProvider(verdict: "SAFE", delay: .seconds(3_600))
    let judge = ConferenceSubmissionJudge(
      provider: provider,
      model: "fixture-model",
      timeout: .milliseconds(10)
    )

    // when / then
    do {
      try await judge.check(
        PreparedConferenceSubmission(
          caseSnapshot: ConferenceWorkflowFixture.item,
          answer: "Use an actor."
        )
      )
      Issue.record("A timed-out judge request was accepted")
    } catch ConferenceError.invalidAnswer {
      #expect(await provider.finished)
    }
  }
}

private actor ConferenceJudgeProvider: LLMProvider {
  let verdict: String
  let fail: Bool
  let delay: Duration
  private(set) var request: ChatRequest?
  private(set) var finished = false

  init(verdict: String, fail: Bool = false, delay: Duration = .zero) {
    self.verdict = verdict
    self.fail = fail
    self.delay = delay
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    self.request = request
    defer { finished = true }
    if fail {
      throw ConferenceError.coderUnavailable("private-provider-diagnostic")
    }
    if delay > .zero {
      try await Task.sleep(for: delay)
    }
    return ChatResponse(content: verdict, finishReason: "stop", usage: .zero, costFromProvider: nil)
  }
}
