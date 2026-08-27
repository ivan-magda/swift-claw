import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationAttemptRunnerFailureTests {
  @Test func firstSendAdmissionStopRemainsAnIncompleteControllerBudgetOutcome() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let provider = FailingStreamingProvider(
      cause: .terminal(status: nil, message: "must not reach provider")
    )
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))
    ).run(
      configuration: configured.configuration,
      sendBudget: EvaluationSendBudgetSnapshot(
        stageAccountedTokens: PageEvaluationContract.pageLimits.accountedTokenThreshold,
        globalAccountedTokens: 0,
        stageResponsesSends: 0,
        globalResponsesSends: 0,
        stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
        stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
      )
    )

    // then — mutant: the former default branch converted a valid controller admission cap into a
    // harness integrity failure, invalidating the batch instead of leaving it incomplete.
    #expect(await provider.streamCalls == 0)
    #expect(result.outcome == .budgetStopped)
    #expect(result.criticalCode == nil)
    #expect(result.replacementReason == EvaluationSendBudgetSnapshot.stageAccountedTokenCap)
    #expect(EvaluationController.isIncompleteFailure(result))
  }

  @Test func deadlineAfterToolResponseDoesNotDuplicateTheProviderCallUsage() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "deadline-dedupe")
    let firstResponse = try #require(
      scriptedTwoRoundResponses(
        firstUsage: ChatUsage(promptTokens: 11, completionTokens: 13, totalTokens: 24)
      ).first
    )
    let provider = SequenceProvider([firstResponse])
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([
        .stream(HTTPStreamHead(statusCode: 200, headers: [:]), [])
      ])
    )
    let request = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: [
        "input": "read the approved input",
        "model": PageEvaluationContract.wireModel,
      ]),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
    )
    _ = try await recorder.openStream(request)
    let clock = ContinuousClock()
    let start = clock.now
    let nowCalls = Mutex(0)

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder,
      providerCallIDGenerator: SequentialCallIDGenerator(),
      runtimeNow: {
        nowCalls.withLock { calls in
          calls += 1
          return calls >= 5 ? start.advanced(by: .seconds(181)) : start
        }
      }
    ).run(
      configuration: configured.configuration,
      sendBudget: EvaluationSendBudgetSnapshot(
        stageAccountedTokens: 0,
        globalAccountedTokens: 0,
        stageResponsesSends: 0,
        globalResponsesSends: 0,
        stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
        stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
      )
    )

    // then — the deadline degradation reuses call-1 and must not append its conservative row twice.
    #expect(await provider.requests.count == 1)
    #expect(result.replacementReason == "deadline")
    #expect(result.http.responsesSends.count == 1)
    #expect(result.usage.count == 1)
    #expect(result.usage.first?.providerCallID == "call-1")
    #expect(result.usage.first?.totalTokens == 24)
    #expect(result.accountedTokens == 24)
  }

  @Test func credentialAndTerminalFreeCausesKeepTheirTypedReplacementClassification() async throws {
    // given — every failure has no scorable output. The typed cause, not a diagnostic string or the
    // broad providerUnavailable degradation, must distinguish frozen replacement eligibility.
    #expect(PageEvaluationContract.runBudget.retryBudget == 1)
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let budget = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
      stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
    )

    func run(_ cause: ProviderError) async throws -> EvaluationAttemptResult {
      let provider = FailingStreamingProvider(cause: cause)
      let roster = ProviderRoster(
        primary: LLMRouteBinding(
          provider: provider,
          wireModel: PageEvaluationContract.wireModel,
          configuredReference: PageEvaluationContract.providerReference,
          costPolicy: .includedPlan,
          reservationPolicy: .chatGPTReplayState
        )
      )
      let result = try await EvaluationAttemptRunner(
        roster: roster,
        httpRecorder: EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))
      ).run(configuration: configured.configuration, sendBudget: budget)
      #expect(await provider.streamCalls == 1)
      return result
    }

    // when
    let terminalFree = try await run(.partialStreamWithoutCompletedTerminal)
    let refreshCompleted = try await run(.credentialRefreshCompleted)
    let refreshExhausted = try await run(.credentialRefreshExhausted)
    let credentialStateUnavailable = try await run(.credentialStateUnavailable)
    let genericTerminal = try await run(.terminal(status: nil, message: "ended"))

    // then — only the exact frozen temporary causes are eligible. A successful durable refresh is
    // still an incomplete original attempt, but it cannot spend a replacement; neither can a marker
    // persistence failure that would let a new worker reload the rejected credential.
    #expect(terminalFree.outcome == .providerFailure)
    #expect(terminalFree.rawOutput == nil)
    #expect(terminalFree.replacementDisposition == .eligible)
    #expect(terminalFree.replacementReason == "partial_stream_without_completed_terminal")
    #expect(refreshCompleted.outcome == .providerFailure)
    #expect(refreshCompleted.rawOutput == nil)
    #expect(refreshCompleted.replacementDisposition == .ineligible)
    #expect(refreshCompleted.replacementReason == "credential_refresh_completed")
    #expect(refreshExhausted.replacementDisposition == .eligible)
    #expect(refreshExhausted.replacementReason == "credential_refresh_exhausted")
    #expect(credentialStateUnavailable.replacementDisposition == .ineligible)
    #expect(credentialStateUnavailable.replacementReason == "credential_state_unavailable")
    #expect(genericTerminal.replacementDisposition == .ineligible)
    #expect(genericTerminal.replacementReason == "provider_terminal")
  }
}
