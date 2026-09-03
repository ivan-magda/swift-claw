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

  @Test func learningSpendNeverLandsOnTheEvaluatedRun() async throws {
    // given — a run that already billed its own answering round
    let env = try EvaluationRunEnvironment.make(reply: EvaluationRunEnvironment.noIssueReply)
    let runSpendBefore = try env.runUsage()

    // when
    await env.runner.runEvaluation(runId: env.runId, now: env.now)

    // then — the evaluator's spend rides the learning scope, never the run it judged
    #expect(try env.runUsage() == runSpendBefore)
    let learning = try env.learningUsage()
    #expect(learning.count == 1)
    #expect(learning.first?.runId == nil)
    #expect(learning.first?.jobId == env.jobId)
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
    #expect(request.maxOutputTokens == LearningOperationRunner.evaluatorOutputTokenCap)
    #expect(
      request.messages.contains { message in
        message.content.text.contains(EvaluationRunEnvironment.defaultFinalOutput)
      }
    )
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
