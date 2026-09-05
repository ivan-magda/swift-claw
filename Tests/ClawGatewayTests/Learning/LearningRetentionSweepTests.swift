import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite struct LearningRetentionSweepTests {
  @Test func failedRecoveryDoesNotPreventCollection() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(reply: EvaluationRunEnvironment.noIssueReply)
    env.authorizing.failBootReconciliation = true
    let workflow = LearningWorkflow(
      store: env.learning,
      jobs: env.jobs,
      runner: env.runner,
      notices: LearningNotices(learning: env.learning, signal: OutboxSignal()),
      redactor: SecretRedactor(secretValues: []),
      logger: TestLog.silent
    )
    let service = ScheduledLearningService(
      store: env.authorizing,
      workflow: workflow,
      logger: TestLog.silent
    )

    // when
    await service.sweep(now: env.now.addingTimeInterval(91 * 86_400))

    // then
    #expect(try env.learning.evidence(runId: env.runId) == nil)
    #expect(try env.learning.workflowRuns(jobId: env.jobId, after: 0, limit: 64).isEmpty)
    #expect(await env.provider.requests.isEmpty)
  }
}
