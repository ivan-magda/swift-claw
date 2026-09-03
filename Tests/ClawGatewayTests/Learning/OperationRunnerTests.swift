import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawData
@testable import ClawGateway

/// One blind, tool-free evaluation per eligible run: nothing reaches the network before the
/// authorize-and-start transaction says so, nothing is retried into a second call, and every
/// verdict lands in the same commit as the operation that paid for it.
@Suite struct OperationRunnerTests {
  @Test func schemaInvalidOutputFailsTheOperationWithNoSecondCall() async throws {
    // given — a reply whose outcome is outside the closed vocabulary
    let env = try EvaluationRunEnvironment.make(
      reply: #"{"schema_version":1,"outcome":"maybe","issue_codes":[]}"#
    )

    // when
    await env.runner.runEvaluation(runId: env.runId, now: env.now)

    // then — there is no schema-repair call, and a failed call commits no verdict
    #expect(await env.provider.requests.count == 1)
    #expect(try env.operationState() == .failed)
    #expect(try env.failureCode() == .schemaInvalid)
    #expect(try env.learning.evaluation(runId: env.runId) == nil)
  }

  @Test func aValidVerdictCommitsWithTheOperationThatBoughtIt() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(
      reply: """
        {"schema_version":1,"outcome":"reusable_issue",\
        "issue_codes":["missed_price_change","empty_answer"]}
        """
    )

    // when
    await env.runner.runEvaluation(runId: env.runId, now: env.now)

    // then — a succeeded operation with no verdict row would be paid-for evidence nothing may
    // ever judge again, because a finished key never claims twice
    #expect(try env.operationState() == .succeeded)
    let verdict = try #require(try env.learning.evaluation(runId: env.runId))
    #expect(verdict.outcome == .reusableIssue)
    #expect(verdict.issueCodes == ["empty_answer", "missed_price_change"])
    #expect(verdict.evaluator.rubricVersion == EvaluatorRubric.v1.version)
  }

  @Test func theChargedRowIsWhatTheEvaluatorCallActuallyBilled() async throws {
    // given — a run that already billed its own answering round
    let env = try EvaluationRunEnvironment.make(reply: EvaluationRunEnvironment.noIssueReply)
    let runSpendBefore = try env.runUsage()

    // when
    await env.runner.runEvaluation(runId: env.runId, now: env.now)

    // then — the runner chooses these numbers, and a call charged at zero or at a guess would let
    // the day's breakers under-count real learning spend for the rest of the day
    let charged = try #require(try env.learningUsage().first)
    #expect(
      charged.tokens
        == EvaluationRunEnvironment.replyPromptTokens
        + EvaluationRunEnvironment.replyCompletionTokens
    )
    #expect(charged.costUSD == EvaluationRunEnvironment.replyCostUSD)
    #expect(charged.costSource == CostSource.providerReturned.rawValue)
    #expect(try env.runUsage() == runSpendBefore)
  }

  @Test func aCarrierNeedingRedactionIsDeniedWithoutACall() async throws {
    // given — the run's own answer quotes a secret, so the exact bytes would change under redaction
    let env = try EvaluationRunEnvironment.make(
      reply: EvaluationRunEnvironment.noIssueReply,
      finalOutput: "The token is sk-live-41 and the price rose.",
      secretValues: ["sk-live-41"]
    )

    // when
    await env.runner.runEvaluation(runId: env.runId, now: env.now)

    // then — denied whole, never sent redacted, and never retried
    #expect(await env.provider.requests.isEmpty)
    #expect(try env.operationState() == .failedNoCall)
    #expect(try env.failureCode() == .carrierPolicyDenied)
  }

  @Test func aTrippedProactiveBreakerClosesTheOperationWithoutACall() async throws {
    // given — the job's own answering round already exhausted the proactive pool
    let env = try EvaluationRunEnvironment.make(
      reply: EvaluationRunEnvironment.noIssueReply,
      proactivePerDayUSD: 0
    )

    // when
    await env.runner.runEvaluation(runId: env.runId, now: env.now)

    // then — the breaker is enforced inside the transaction, and the runner honors its verdict
    #expect(await env.provider.requests.isEmpty)
    #expect(try env.operationState() == .failedNoCall)
    #expect(try env.failureCode() == .budgetDenied)
  }

  @Test func theEvaluatorRequestCarriesNoToolsAndCapsItsOutput() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(reply: EvaluationRunEnvironment.noIssueReply)

    // when
    await env.runner.runEvaluation(runId: env.runId, now: env.now)

    // then — a judging call that could act would stop being a judgement
    let request = try #require(await env.provider.requests.first)
    #expect(request.tools.isEmpty)
    // The literal, deliberately: `scheduled-learning/v1` fixes the evaluator output cap at 512, and
    // comparing the constant to itself would let that versioned parameter change in silence.
    #expect(request.maxOutputTokens == 512)
    #expect(
      request.messages.contains { message in
        message.content.text.contains(EvaluationRunEnvironment.defaultFinalOutput)
      }
    )
  }

  @Test func aSupersededAuthorizationSendsNothingAndRecordsNoVerdict() async throws {
    // given — a claim that stopped describing work worth doing between the claim and the network
    let log = RecordingLogCapture()
    let env = try EvaluationRunEnvironment.make(
      reply: EvaluationRunEnvironment.noIssueReply,
      supersedeAuthorization: true,
      logger: log.logger()
    )

    // when
    await env.runner.runEvaluation(runId: env.runId, now: env.now)

    // then — dispatching here would buy a real call whose commit finds the row out of `started`,
    // drop the spend with no usage row anywhere, and leave a receipt no policy ever refused
    #expect(await env.provider.requests.isEmpty)
    #expect(try env.evaluationRowCount() == 0)
    #expect(try env.learningUsage().isEmpty)
    #expect(log.entries.contains { $0.level >= .error } == false)
  }

  @Test func aFencedReplyIsJudgedRatherThanBurned() async throws {
    // given — the code fence models add despite being told not to
    let env = try EvaluationRunEnvironment.make(
      reply: "```json\n\(EvaluationRunEnvironment.noIssueReply)\n```"
    )

    // when
    await env.runner.runEvaluation(runId: env.runId, now: env.now)

    // then — punctuation must not close the key forever: `claim` never reopens a finished one, so
    // failing here would make this run's paid-for evidence permanently unjudgeable
    #expect(try env.operationState() == .succeeded)
    #expect(try env.learning.evaluation(runId: env.runId)?.outcome == .noIssue)
  }

  @Test func theCallStartsOnTheConfiguredRouteAndRecordsTheOneThatServedIt() async throws {
    // given — a primary whose plan quota is out and a fallback that answers
    let env = try EvaluationRunEnvironment.make(
      reply: EvaluationRunEnvironment.noIssueReply,
      primaryFailure: ProviderError.quotaLimited(retryAfterSeconds: nil)
    )

    // when
    await env.runner.runEvaluation(runId: env.runId, now: env.now)

    // then — the two routes stay distinguishable, which is what the compatibility digest hashes
    #expect(try env.operationState() == .succeeded)
    #expect(try env.operationRoute() == EvaluationRunEnvironment.primaryRoute)
    #expect(try env.evaluatorRoute() == EvaluationRunEnvironment.fallbackRoute)
    #expect(try env.learningUsage().first?.model == EvaluationRunEnvironment.fallbackRoute)
  }
}
