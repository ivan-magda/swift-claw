import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite
struct LearningWorkflowTests {
  @Test
  func settlementChain() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(reply: EvaluationRunEnvironment.noIssueReply)
    let workflow = LearningWorkflow(
      store: env.learning,
      jobs: env.jobs,
      runner: env.runner,
      notices: LearningNotices(learning: env.learning, signal: OutboxSignal()),
      redactor: SecretRedactor(secretValues: []),
      logger: TestLog.silent
    )
    let service = ScheduledLearningService(
      store: env.learning,
      workflow: workflow,
      now: {
        env.now
      },
      logger: TestLog.silent
    )
    // when
    await service.advance(runID: env.runID)
    await service.advance(runID: env.runID)
    // then
    #expect(try env.learning.evaluation(runID: env.runID)?.outcome == .noIssue)
    #expect(await env.provider.requests.count == 1)
    #expect(try env.evaluationAuditCount() == 1)
  }
}

extension LearningWorkflowTests {
  static let negative =
    #"{"schema_version":1,"outcome":"reusable_issue","issue_codes":["material.missed"]}"#

  @Test
  func secondNegativeOpensTrialAndNotifies() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(
      reply: Self.negative,
      followingReplies: [Self.negative, ReflectionRunEnvironment.candidateReply],
      repeatable: true,
      sealsEvidence: false
    )
    let service = Self.service(env)
    await service.advance(runID: env.runID)
    #expect(try env.learning.openTrial(jobID: env.jobID) == nil)
    let second = try env.settledBoundRun()
    // when
    await service.advance(runID: second)
    await service.advance(jobID: env.jobID)
    // then
    let trial = try #require(try env.learning.openTrial(jobID: env.jobID))
    #expect(trial.consumedAssignments == 0)
    #expect(await env.provider.requests.count == 3)
    let targets = try env.candidateTargets()
    #expect(
      targets.contains {
        $0.subjectDigest == trial.candidateDigest.rawValue
          && $0.allowedActions == [.candidateReject, .candidateEdit]
      }
    )
  }

  @Test
  func sweepRecoversSealedEvidenceAndDeadline() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(
      reply: Self.negative,
      followingReplies: [Self.negative, ReflectionRunEnvironment.candidateReply],
      repeatable: true
    )
    let service = Self.service(env)
    // when
    await service.sweep(now: env.now)
    let second = try env.settledBoundRun()
    await service.advance(runID: second)
    let trial = try #require(try env.learning.openTrial(jobID: env.jobID))
    await service.sweep(now: trial.assignmentDeadline)
    await service.sweep(now: trial.assignmentDeadline)
    // then
    #expect(try env.learning.evaluation(runID: env.runID) != nil)
    #expect(try env.learning.openTrial(jobID: env.jobID) == nil)
    #expect(try env.learning.learningState(jobID: env.jobID)?.stableDigest == trial.baseDigest)
    #expect(await env.provider.requests.count == 3)
  }

  @Test
  func terminalReflectionWaitsWithoutRetry() async throws {
    // given
    let env = try ReflectionRunEnvironment.make(reply: #"{"schema_version":1,"candidate":null}"#)
    let workflow = LearningWorkflow(
      store: env.learning,
      jobs: env.jobs,
      runner: env.runner,
      notices: LearningNotices(learning: env.learning, signal: OutboxSignal()),
      redactor: SecretRedactor(secretValues: []),
      logger: TestLog.silent
    )
    let service = ScheduledLearningService(
      store: env.learning,
      workflow: workflow,
      now: {
        env.now
      },
      logger: TestLog.silent
    )
    // when
    await service.advance(jobID: env.jobID)
    await service.sweep(now: env.now)
    // then
    #expect(await env.provider.requests.count == 1)
    #expect(try env.learning.openTrial(jobID: env.jobID) == nil)
  }

  @Test
  func budgetDeniedWaitsWithoutRetry() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(
      reply: Self.negative,
      repeatable: true,
      proactivePerDayUSD: 0
    )
    let service = Self.service(env)
    // when
    await service.advance(runID: env.runID)
    await service.sweep(now: env.now)
    // then
    #expect(await env.provider.requests.isEmpty)
    #expect(try env.failureCode() == .budgetDenied)
    #expect(try env.learning.openTrial(jobID: env.jobID) == nil)
  }

  @Test
  func failedBootReconciliationNeverDispatches() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(reply: EvaluationRunEnvironment.noIssueReply)
    env.authorizing.failBootReconciliation = true
    let service = Self.service(env, bootStore: env.authorizing)
    // when
    await service.reconcileAtBoot(now: env.now)
    await service.advance(runID: env.runID)
    await service.sweep(now: env.now)
    // then
    #expect(await env.provider.requests.isEmpty)
    #expect(try env.learning.evaluation(runID: env.runID) == nil)
    // when
    env.authorizing.failBootReconciliation = false
    await service.sweep(now: env.now)
    // then
    #expect(try env.learning.evaluation(runID: env.runID)?.outcome == .noIssue)
    #expect(await env.provider.requests.count == 1)
  }
}

// MARK: - Workflow Service Fixtures

private extension LearningWorkflowTests {
  static func service(
    _ env: EvaluationRunEnvironment,
    bootStore: (any ScheduledLearningStore)? = nil
  ) -> ScheduledLearningService {
    let workflow = LearningWorkflow(
      store: env.learning,
      jobs: env.jobs,
      runner: env.runner,
      notices: LearningNotices(learning: env.learning, signal: OutboxSignal()),
      redactor: SecretRedactor(secretValues: []),
      logger: TestLog.silent
    )
    return ScheduledLearningService(
      store: bootStore ?? env.learning,
      workflow: workflow,
      now: {
        env.now
      },
      logger: TestLog.silent
    )
  }
}

extension LearningWorkflowTests {
  @Test
  func concurrentAdvancesClaimOneInference() async throws {
    // given
    let entered = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let env = try EvaluationRunEnvironment.make(
      reply: EvaluationRunEnvironment.noIssueReply,
      beforeResponse: {
        entered.open()
        await release.wait()
      }
    )
    let service = Self.service(env)
    // when
    let first = Task {
      await service.advance(runID: env.runID)
    }
    await entered.wait()
    await service.advance(runID: env.runID)
    #expect(await env.provider.requests.count == 1)
    release.open()
    await first.value
    // then
    #expect(try env.learning.evaluation(runID: env.runID)?.outcome == .noIssue)
    #expect(await env.provider.requests.count == 1)
  }

  @Test
  func realEditReplyCreatesUnapprovedSuccessorAndRealApprovalAdmitsIt() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(
      reply: Self.negative,
      followingReplies: [Self.negative, ReflectionRunEnvironment.candidateReply],
      repeatable: true
    )
    let service = Self.service(env)
    await service.advance(runID: env.runID)
    await service.advance(runID: try env.settledBoundRun())
    let original = try #require(try env.learning.openTrial(jobID: env.jobID))
    let target = try #require(try env.candidateTargets().first)
    let router = try env.workflowRouter(service: service)
    // when
    _ = await router.handle(rawUpdate: env.callback(target: target, action: .candidateEdit, id: 1))
    _ = await router.handle(
      rawUpdate: textUpdate(
        id: 2,
        from: EvaluationRunEnvironment.chatID,
        text: #"{"lessons":["Report price changes only."]}"#
      )
    )
    await service.waitForPendingWork()
    await service.sweep(now: env.now)
    // then
    #expect(try env.learning.openTrial(jobID: env.jobID) == nil)
    #expect(await env.provider.requests.count == 3)
    let successorTarget = try #require(
      try env.candidateTargets().first {
        $0.subjectDigest != original.candidateDigest.rawValue
      }
    )
    #expect(successorTarget.allowedActions.contains(.candidateApprove))
    let successor = try #require(
      try env.learning.candidateArtifact(
        digest: CandidateDigest(rawValue: successorTarget.subjectDigest)
      )
    )
    #expect(successor.manifest.origin == .ownerEdit)
    #expect(successor.manifest.predecessorCandidate == original.candidateDigest)
    // when
    _ = await router.handle(
      rawUpdate: env.callback(target: successorTarget, action: .candidateApprove, id: 3)
    )
    await service.waitForPendingWork()
    // then
    let approved = try #require(try env.learning.openTrial(jobID: env.jobID))
    #expect(approved.candidateDigest != successor.digest)
    #expect(approved.replacementDigest == successor.replacement.digest)
    #expect(await env.provider.requests.count == 3)
  }

  @Test
  func realRollbackTapRestoresRetainedBase() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(
      reply: Self.negative,
      followingReplies: [
        Self.negative,
        ReflectionRunEnvironment.candidateReply,
        EvaluationRunEnvironment.noIssueReply,
        EvaluationRunEnvironment.noIssueReply,
      ],
      repeatable: true
    )
    let service = Self.service(env)
    await service.advance(runID: env.runID)
    await service.advance(runID: try env.settledBoundRun())
    await service.advance(runID: try env.settledBoundRun())
    await service.advance(runID: try env.settledBoundRun())
    let promotion = try #require(try env.learning.currentPromotion(jobID: env.jobID))
    let router = try env.workflowRouter(service: service)
    _ = await router.handle(
      rawUpdate: textUpdate(
        id: 10,
        from: EvaluationRunEnvironment.chatID,
        text: "/learning \(env.jobID)"
      )
    )
    let target = try #require(try env.promotionTarget())
    // when
    _ = await router.handle(
      rawUpdate: env.callback(target: target, action: .promotionRollback, id: 11)
    )
    await service.waitForPendingWork()
    // then
    #expect(
      try env.learning.learningState(jobID: env.jobID)?.stableDigest == promotion.inputs.baseDigest
    )
    #expect(try env.learning.currentPromotion(jobID: env.jobID) == nil)
  }
}

extension LearningWorkflowTests {
  @Test
  func correctionAcknowledgementDoesNotWaitForReflection() async throws {
    // given
    let setupFinished = AsyncGate()
    let entered = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let env = try EvaluationRunEnvironment.make(
      reply: EvaluationRunEnvironment.noIssueReply,
      followingReplies: [ReflectionRunEnvironment.candidateReply],
      repeatable: true,
      beforeResponse: {
        if setupFinished.isOpen {
          entered.open()
          await release.wait()
        }
      }
    )
    let service = Self.service(env)
    await service.advance(runID: env.runID)
    setupFinished.open()
    let state = try #require(try env.learning.learningState(jobID: env.jobID))
    let target = NewFeedbackTarget(
      nonce: "workflow-correction",
      jobID: env.jobID,
      epoch: state.epoch,
      subjectKind: .run,
      subjectDigest: String(env.runID),
      allowedActions: [.resultCorrection],
      ownerUserID: EvaluationRunEnvironment.chatID,
      chatID: EvaluationRunEnvironment.chatID,
      expiresAt: env.now.addingTimeInterval(3_600)
    )
    try TestLearningFixtures(writer: env.queue).seedTargets([target])
    let stored = try #require(try env.learning.feedbackTarget(nonce: target.nonce))
    let router = try env.workflowRouter(service: service)
    // when
    _ = await router.handle(
      rawUpdate: env.callback(target: stored, action: .resultCorrection, id: 1)
    )
    let acknowledgement = await router.handle(
      rawUpdate: textUpdate(
        id: 2,
        from: EvaluationRunEnvironment.chatID,
        text: "Report material price changes."
      )
    )
    await entered.wait()
    // then
    #expect(acknowledgement == .processed)
    #expect(try env.learning.openTrial(jobID: env.jobID) == nil)
    release.open()
    await service.waitForPendingWork()
    #expect(try env.learning.openTrial(jobID: env.jobID) != nil)
  }
}

extension LearningWorkflowTests {
  @Test
  func sweepRecoversArtifactAbandonedBeforeAdmissionAndNotice() async throws {
    // given
    let env = try ReflectionRunEnvironment.make(admissionFails: true)
    await env.runner.runReflection(trigger: env.trigger, now: env.now)
    #expect(try env.learning.openTrial(jobID: env.jobID) == nil)
    let workflow = LearningWorkflow(
      store: env.learning,
      jobs: env.jobs,
      runner: env.runner,
      notices: LearningNotices(learning: env.learning, signal: OutboxSignal()),
      redactor: SecretRedactor(secretValues: []),
      logger: TestLog.silent
    )
    let service = ScheduledLearningService(
      store: env.learning,
      workflow: workflow,
      now: {
        env.now
      },
      logger: TestLog.silent
    )
    // when
    await service.sweep(now: env.now)
    // then
    #expect(try env.learning.openTrial(jobID: env.jobID) != nil)
    #expect(try env.rowCount("feedback_targets") > 0)
    #expect(await env.provider.requests.count == 1)
  }

  @Test
  func reflectorBudgetDenialStopsMidChain() async throws {
    // given
    let env = try ReflectionRunEnvironment.make(proactivePerDayUSD: 0)
    let workflow = LearningWorkflow(
      store: env.learning,
      jobs: env.jobs,
      runner: env.runner,
      notices: LearningNotices(learning: env.learning, signal: OutboxSignal()),
      redactor: SecretRedactor(secretValues: []),
      logger: TestLog.silent
    )
    let service = ScheduledLearningService(
      store: env.learning,
      workflow: workflow,
      now: {
        env.now
      },
      logger: TestLog.silent
    )
    // when
    await service.advance(jobID: env.jobID)
    await service.sweep(now: env.now)
    // then
    #expect(await env.provider.requests.isEmpty)
    #expect(try env.failureCode() == .budgetDenied)
    #expect(try env.learning.openTrial(jobID: env.jobID) == nil)
  }
}

extension LearningWorkflowTests {
  @Test
  func transitionBudgetYieldsAndCompletedWindowsDoNotStarveLaterWork() async throws {
    // given
    let transitionLimit = 2
    let windowCount = transitionLimit + 1
    let evaluationCount = windowCount * LearningTrigger.recurringRunThreshold
    let noCandidate = #"{"schema_version":1,"candidate":null}"#
    let replies =
      Array(repeating: Self.negative, count: evaluationCount - 1)
        + Array(repeating: noCandidate, count: windowCount)
    let env = try EvaluationRunEnvironment.make(
      reply: Self.negative,
      followingReplies: replies,
      repeatable: true
    )
    await env.runner.runEvaluation(runID: env.runID, now: env.now)
    for index in 1..<evaluationCount {
      let window = index / LearningTrigger.recurringRunThreshold
      let catalog = window == 0 ? "tools-v1" : "tools-version-\(window)"
      let runID = try env.settledBoundRun(toolCatalog: catalog)
      try env.learning.sealEvidence(runID: runID, now: env.now)
      await env.runner.runEvaluation(runID: runID, now: env.now)
    }
    let logs = RecordingLogCapture()
    let workflow = LearningWorkflow(
      store: env.learning,
      jobs: env.jobs,
      runner: env.runner,
      notices: LearningNotices(learning: env.learning, signal: OutboxSignal()),
      redactor: SecretRedactor(secretValues: []),
      logger: logs.logger()
    )
    // when
    await workflow.advance(jobID: env.jobID, now: env.now, transitionLimit: transitionLimit)
    // then
    #expect(await env.provider.requests.count == evaluationCount + transitionLimit)
    #expect(
      logs.entries.contains {
        $0.level == .error && $0.message.contains("learning workflow hit its transition budget")
      }
    )
    // when
    await workflow.advance(jobID: env.jobID, now: env.now, transitionLimit: transitionLimit)
    // then
    #expect(await env.provider.requests.count == evaluationCount + windowCount)
  }
}

extension LearningWorkflowTests {
  enum SourceChange: CaseIterable { case evidence, ownerOutcome }

  @Test(arguments: SourceChange.allCases)
  func actualSourceChangeAfterEditCanReflect(_ change: SourceChange) async throws {
    // given
    let newReplies = change == .evidence ? [Self.negative] : []
    let env = try EvaluationRunEnvironment.make(
      reply: Self.negative,
      followingReplies: [Self.negative, ReflectionRunEnvironment.candidateReply] + newReplies + [
        #"{"schema_version":1,"candidate":null}"#,
      ],
      repeatable: true
    )
    let service = Self.service(env)
    await service.advance(runID: env.runID)
    await service.advance(runID: try env.settledBoundRun())
    let candidate = try #require(try env.candidateTargets().first)
    let router = try env.workflowRouter(service: service)
    _ = await router.handle(
      rawUpdate: env.callback(target: candidate, action: .candidateEdit, id: 1)
    )
    _ = await router.handle(
      rawUpdate: textUpdate(
        id: 2,
        from: EvaluationRunEnvironment.chatID,
        text: #"{"lessons":["Report price changes only."]}"#
      )
    )
    await service.waitForPendingWork()
    #expect(await env.provider.requests.count == 3)
    // when
    switch change {
    case .evidence: await service.advance(runID: try env.settledBoundRun())
    case .ownerOutcome:
      let target = NewFeedbackTarget(
        nonce: "new-source-outcome",
        jobID: env.jobID,
        epoch: candidate.epoch,
        subjectKind: .run,
        subjectDigest: String(env.runID),
        allowedActions: [.resultNotUseful],
        ownerUserID: EvaluationRunEnvironment.chatID,
        chatID: EvaluationRunEnvironment.chatID,
        expiresAt: candidate.expiresAt
      )
      try TestLearningFixtures(writer: env.queue).seedTargets([target])
      let stored = try #require(try env.learning.feedbackTarget(nonce: target.nonce))
      _ = await router.handle(
        rawUpdate: env.callback(target: stored, action: .resultNotUseful, id: 3)
      )
      await service.waitForPendingWork()
    }
    // then
    #expect(await env.provider.requests.count == 4 + newReplies.count)
  }
}

extension LearningWorkflowTests {
  @Test
  func realNegativeFeedbackDecidesTheOpenTrial() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(
      reply: Self.negative,
      followingReplies: [
        Self.negative,
        ReflectionRunEnvironment.candidateReply,
        EvaluationRunEnvironment.noIssueReply,
      ],
      repeatable: true
    )
    let service = Self.service(env)
    await service.advance(runID: env.runID)
    await service.advance(runID: try env.settledBoundRun())
    let trial = try #require(try env.learning.openTrial(jobID: env.jobID))
    let runID = try env.settledBoundRun()
    await service.advance(runID: runID)
    let target = NewFeedbackTarget(
      nonce: "negative-trial-run",
      jobID: env.jobID,
      epoch: trial.epoch,
      subjectKind: .run,
      subjectDigest: String(runID),
      allowedActions: [.resultNotUseful],
      ownerUserID: EvaluationRunEnvironment.chatID,
      chatID: EvaluationRunEnvironment.chatID,
      expiresAt: trial.assignmentDeadline
    )
    try TestLearningFixtures(writer: env.queue).seedTargets([target])
    let stored = try #require(try env.learning.feedbackTarget(nonce: target.nonce))
    let router = try env.workflowRouter(service: service)
    // when
    _ = await router.handle(
      rawUpdate: env.callback(target: stored, action: .resultNotUseful, id: 1)
    )
    await service.waitForPendingWork()
    // then
    #expect(try env.learning.openTrial(jobID: env.jobID) == nil)
    #expect(try env.learning.learningState(jobID: env.jobID)?.stableDigest == trial.baseDigest)
  }

  @Test
  func bootReturnsAnUnstartedClaimToTheWorkflow() async throws {
    // given
    let env = try EvaluationRunEnvironment.make(reply: EvaluationRunEnvironment.noIssueReply)
    let evidence = try #require(try env.learning.evidence(runID: env.runID))
    let key = LearningOperationKey(
      jobID: env.jobID,
      epoch: evidence.epoch,
      phase: .evaluator,
      sourceDigest: evidence.digest.rawValue,
      promptVersion: EvaluatorPrompt.v1.version,
      schemaVersion: EvaluatorOutput.currentSchemaVersion,
      rubricVersion: EvaluatorRubric.v1.version
    )
    _ = try #require(try env.learning.claimOperation(key, now: env.now))
    let service = Self.service(env)
    // when
    await service.reconcileAtBoot(now: env.now)
    await service.sweep(now: env.now)
    // then
    #expect(try env.learning.evaluation(runID: env.runID)?.outcome == .noIssue)
    #expect(await env.provider.requests.count == 1)
  }
}

extension LearningWorkflowTests {
  @Test
  func explicitBootPreservesNotificationStartedInference() async throws {
    // given
    let entered = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let env = try EvaluationRunEnvironment.make(
      reply: EvaluationRunEnvironment.noIssueReply,
      beforeResponse: {
        entered.open()
        await release.wait()
      }
    )
    let service = Self.service(env)
    await service.notifySettled(runID: env.runID)
    await entered.wait()
    // when
    await service.reconcileAtBoot(now: env.now)
    // then
    #expect(try env.operationState() == .started)
    #expect(try env.learningUsage().isEmpty)
    release.open()
    await service.waitForPendingWork()
    await service.sweep(now: env.now)
    #expect(try env.operationState() == .succeeded)
    #expect(try env.learning.evaluation(runID: env.runID)?.outcome == .noIssue)
    #expect(await env.provider.requests.count == 1)
    let usages = try env.learningUsage()
    #expect(usages.count == 1)
    let usage = try #require(usages.first)
    #expect(usage.costUSD == EvaluationRunEnvironment.replyCostUSD)
    #expect(
      usage.tokens == EvaluationRunEnvironment.replyPromptTokens
        + EvaluationRunEnvironment.replyCompletionTokens
    )
  }
}

extension LearningWorkflowTests {
  @Test
  func runtimeCancellationJoinsNotificationStartedInference() async throws {
    // given
    let setupFinished = AsyncGate()
    let entered = AsyncGate()
    let release = AsyncGate()
    let returned = AsyncGate()
    let sweeping = AsyncGate()
    defer { release.open() }
    let env = try EvaluationRunEnvironment.make(
      reply: Self.negative,
      followingReplies: [
        Self.negative,
        EvaluationRunEnvironment.noIssueReply,
        #"{"schema_version":1,"candidate":null}"#,
      ],
      repeatable: true,
      beforeResponse: {
        guard setupFinished.isOpen else {
          return
        }
        entered.open()
        await release.wait()
        returned.open()
      }
    )
    let bootStore = RecordingLearningStore(base: env.learning, onUnsealed: sweeping.open)
    let service = Self.service(env, bootStore: bootStore)
    await service.advance(runID: env.runID)
    setupFinished.open()
    let secondRun = try env.settledBoundRun()
    await service.notifySettled(runID: secondRun)
    await entered.wait()

    // when
    let runtime = Task {
      try await service.run()
    }
    await sweeping.wait()
    runtime.cancel()
    _ = await runtime.result

    // then
    #expect(release.isOpen == false)
    #expect(returned.isOpen)
    #expect(try env.learning.evaluation(runID: secondRun)?.outcome == .reusableIssue)
    #expect(try env.learningUsage().count == 2)
    #expect(await env.provider.requests.count == 2)

    // when
    let lateRun = try env.settledBoundRun()
    await service.notifySettled(runID: lateRun)
    await service.waitForPendingWork()

    // then
    #expect(try env.learning.evaluation(runID: lateRun) == nil)
    #expect(await env.provider.requests.count == 2)
    release.open()
    let restarted = Self.service(env)
    await restarted.sweep(now: env.now)
    #expect(try env.learning.evaluation(runID: lateRun)?.outcome == .noIssue)
  }
}
