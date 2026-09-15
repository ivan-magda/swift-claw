import ClawAgent
import ClawCore
import ClawTestSupport
import ClawWorkspace
import Foundation
import GRDB
import Testing

@testable import ClawData
@testable import ClawGateway

/// A bound run answers against the exact lesson set its fire froze, or it does not run at all.
///
/// Substituting the job's current set — or running on lessons that belong to another job — would
/// evaluate a hypothesis the binding never froze, and every later decision reads that evidence.
@Suite
struct PinnedLessonTests {
  @Test
  func aBoundRunNeverSubstitutesTheCurrentStableSet() async throws {
    // given — the job's stable pointer moved after this run was bound
    let env = try PinnedLessonEnvironment.make()
    let pinned = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()
    let promoted = try env.pinStableSet(["Report every heading."])

    // when
    try await env.runner.run(
      runID: fired.runID,
      sessionID: fired.sessionID,
      chatID: env.chatID,
      triggerMessageID: fired.triggerMessageID
    )

    // then — the frozen set reached the model; the newer one never did
    let sent = try #require(await env.provider.requests.first).renderedContext
    #expect(sent.contains(pinned.lessons[0]))
    #expect(sent.contains(promoted.lessons[0]) == false)
    #expect(try env.runState(runID: fired.runID) == .done)
  }

  @Test
  func pinnedLessonsTaintTheRunTheyAreAssembledInto() async throws {
    // given — an untainted session and a job whose bound run carries lessons
    let env = try PinnedLessonEnvironment.make()
    _ = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()

    // when
    try await env.runner.run(
      runID: fired.runID,
      sessionID: fired.sessionID,
      chatID: env.chatID,
      triggerMessageID: fired.triggerMessageID
    )

    // then — a model wrote those lessons, so the run leaves its session tainted
    #expect(try env.sessionIsTainted(sessionID: fired.sessionID))
  }

  @Test
  func aBindingThatNamesAnotherJobFailsTheRunBeforeDispatch() async throws {
    // given — a second job holding the identical lessons, so the digest alone still resolves
    let env = try PinnedLessonEnvironment.make()
    let pinned = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()
    let otherJobID = try env.armSecondJob(holding: pinned)
    try env.rebindJob(runID: fired.runID, to: otherJobID)

    // when
    try await env.runner.run(
      runID: fired.runID,
      sessionID: fired.sessionID,
      chatID: env.chatID,
      triggerMessageID: fired.triggerMessageID
    )

    // then — the run fails on the identity the digest cannot carry, before any provider call
    #expect(await env.provider.callCount == 0)
    #expect(try env.runState(runID: fired.runID) == .failed)
  }

  @Test
  func aRunWithNoBindingStillRunsWhileLearningIsArmed() async throws {
    // given — the inbound turn every armed daemon serves between fires
    let env = try PinnedLessonEnvironment.make()
    _ = try env.pinStableSet(["Report only price changes."])
    let inbound = try env.inboundRun()

    // when
    try await env.runner.run(
      runID: inbound.runID,
      sessionID: inbound.sessionID,
      chatID: env.chatID,
      triggerMessageID: inbound.triggerMessageID
    )

    // then — no binding, no lesson row, no failure
    let sent = try #require(await env.provider.requests.first).renderedContext
    #expect(sent.contains(ContextBuilder.lessonsLabel) == false)
    #expect(try env.runState(runID: inbound.runID) == .done)
  }

  @Test
  func aBindingWrittenBeforeTheFlagCameOffIsIgnored() async throws {
    // given — a run bound while learning was armed, resuming under a disarmed daemon
    let env = try PinnedLessonEnvironment.make(learning: { _ in
      nil
    })
    let pinned = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()

    // when
    try await env.runner.run(
      runID: fired.runID,
      sessionID: fired.sessionID,
      chatID: env.chatID,
      triggerMessageID: fired.triggerMessageID
    )

    // then — the flag is a kill switch: no row, no taint, and the run still completes
    let sent = try #require(await env.provider.requests.first).renderedContext
    #expect(sent.contains(pinned.lessons[0]) == false)
    #expect(try env.sessionIsTainted(sessionID: fired.sessionID) == false)
    #expect(try env.runState(runID: fired.runID) == .done)
  }

  @Test
  func anUnresolvablePinnedSetFailsTheRunBeforeDispatch() async throws {
    // given — the binding's set cannot be read back. The schema's composite foreign key keeps this
    // out of a real database, so the store is wrapped to produce the one fact under test.
    let env = try PinnedLessonEnvironment.make(learning: { store in
      UnresolvableLessonSets(base: store)
    })
    _ = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()

    // when
    try await env.runner.run(
      runID: fired.runID,
      sessionID: fired.sessionID,
      chatID: env.chatID,
      triggerMessageID: fired.triggerMessageID
    )

    // then — the run fails rather than answering with no lessons at all
    #expect(await env.provider.callCount == 0)
    #expect(try env.runState(runID: fired.runID) == .failed)
  }

  @Test
  func aResumeLoadsTheSamePinnedSetTheDispatchUsed() async throws {
    // given — a bound run already picked up, as an approval's continuation finds it. The suspend
    // choreography is elided: the pinned read depends on the run's binding, not on how it parked.
    let env = try PinnedLessonEnvironment.make()
    let pinned = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()
    _ = try env.runs.pickUp(runID: fired.runID, now: env.now)

    // when
    await env.runner.resume(
      runID: fired.runID,
      sessionID: fired.sessionID,
      chatID: env.chatID,
      contextBoundMessageID: fired.triggerMessageID
    )

    // then
    let sent = try #require(await env.provider.requests.first).renderedContext
    #expect(sent.contains(pinned.lessons[0]))
  }

  @Test
  func aCompletedBoundScheduledRunCommitsOneTargetAndOnlyFinalChunkKeyboard() async throws {
    // given — enough content to force multiple result chunks, with a deterministic opaque address
    let answer = String(repeating: "a", count: ReplySplitter.limit + 64)
    let env = try PinnedLessonEnvironment.make(
      responseContent: answer,
      makeFeedbackNonce: {
        "scheduled-feedback-nonce"
      }
    )
    _ = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()

    // when
    try await env.runner.run(
      runID: fired.runID,
      sessionID: fired.sessionID,
      chatID: env.chatID,
      triggerMessageID: fired.triggerMessageID
    )

    // then — the runner derives the exact run target and attaches its keyboard only at the end
    let target = try #require(try env.learning.feedbackTarget(nonce: "scheduled-feedback-nonce"))
    #expect(target.jobID == env.jobID)
    #expect(target.epoch == LearningEpoch(1))
    #expect(target.subjectKind == .run)
    #expect(target.subjectDigest == String(fired.runID))
    #expect(target.allowedActions == [.resultUseful, .resultNotUseful, .resultCorrection])
    #expect(target.ownerUserID == env.chatID)
    #expect(target.chatID == env.chatID)
    #expect(target.expiresAt == env.now.addingTimeInterval(EvidenceWindow.maximumAge))
    let chunks = try OutboxStoreGRDB(writer: env.queue).pendingOutbound()
    #expect(chunks.count > 1)
    #expect(
      chunks.dropLast().allSatisfy {
        $0.replyMarkup == nil
      }
    )
    #expect(chunks.last?.replyMarkup == LearningNotices.resultKeyboard(target: target.newTarget))
  }
}

// MARK: - Fixture

private extension ChatRequest {
  /// The whole assembled prompt as the provider receives it.
  var renderedContext: String { messages.map(\.content.text).joined(separator: "\n") }
}

/// A migrated database holding one armed scheduled job, the real fire path that binds its runs, and
/// a `TurnRunner` wired to the same learning store the daemon composes.
private struct PinnedLessonEnvironment {
  let queue: DatabaseQueue
  let runner: TurnRunner
  let provider: StubLLMProvider
  let jobs: ScheduledJobStoreGRDB
  let runs: RunStoreGRDB
  let learning: ScheduledLearningStoreGRDB
  let sessionMessages: SessionMessageStoreGRDB
  let jobID: Int64
  let chatID: Int64
  let now: Date

  /// Builds a persisted scheduled run with controllable pinned-lesson reads.
  ///
  /// - Parameters:
  ///   - responseContent: The provider's scripted answer for the run.
  ///   - makeFeedbackNonce: Creates feedback identities for the fixture's deliveries.
  ///   - wiring: Wraps the real learning store, or returns nil to model a disarmed daemon.
  ///     A wrapper can expose unreadable lessons that the schema prevents storing directly.
  /// - Returns: The run's stores, runtime, and frozen identities.
  /// - Throws: A fixture preparation error if the persisted environment cannot be created.
  static func make(
    responseContent: String = "done",
    makeFeedbackNonce: @escaping @Sendable () -> String = {
      OpaqueNonce.generate()
    },
    learning wiring: (_ store: ScheduledLearningStoreGRDB) -> (any ScheduledLearningStore)? = {
      store in
      store
    }
  ) throws -> PinnedLessonEnvironment {
    let queue = try TestDatabase.make()
    let chatID: Int64 = 777
    let now = Date(timeIntervalSince1970: 1_782_000_600)

    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatID: chatID,
        label: "digest",
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    _ = try TestLearningFixtures(writer: queue).seedArmedJob(jobID: job.id, now: now)

    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let usage = UsageStoreGRDB(writer: queue)
    let audit = AuditLogGRDB(writer: queue)
    let provider = StubLLMProvider(
      .respond(
        ChatResponse(
          content: responseContent,
          finishReason: "stop",
          usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
          costFromProvider: 0.0021
        )
      )
    )
    let runner = TurnRunner(
      sessionMessages: sessionMessages,
      runs: RunStoreGRDB(writer: queue),
      usageStore: usage,
      audit: audit,
      agent: AgentRuntime(
        roster: makeSingleRouteRoster(provider: provider, wireModel: "gpt-4o"),
        typingIndicator: NoopTyping(),
        draftStreamer: NoopRichDraftStreaming(),
        streamingEnabled: false,
        costResolver: CostResolver(
          priceTable: .empty,
          referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
        ),
        budget: .default,
        usageStore: usage,
        auditLog: audit,
        clock: ContinuousClock()
      ),
      contextBuilder: ContextBuilder(
        systemPrompt: SystemPrompt.minimal,
        proactiveSystemPrompt: "proactive policy",
        workspace: EmptyWorkspace(),
        memoryStore: EmptyMemoryStore(),
        retriever: EmptyRetriever(),
        budget: .default,
        now: {
          now
        }
      ),
      imageCache: ImageCache(),
      notifyOutbox: {},
      now: {
        now
      },
      learning: wiring(learning),
      makeFeedbackNonce: makeFeedbackNonce,
      parker: InertApprovalParker(coordinator: ApprovalCoordinator()),
      approvalExpirySeconds: testApprovalExpirySeconds,
      logger: TestLog.silent
    )

    return PinnedLessonEnvironment(
      queue: queue,
      runner: runner,
      provider: provider,
      jobs: jobs,
      runs: RunStoreGRDB(writer: queue),
      learning: learning,
      sessionMessages: sessionMessages,
      jobID: job.id,
      chatID: chatID,
      now: now
    )
  }

  /// Stores a set for this job and makes it the job's stable pointer, which is what the next fire
  /// binds against.
  func pinStableSet(_ lessons: [String]) throws -> LessonSet {
    let set = try LessonSet.canonical(jobID: jobID, lessons: lessons)
    try insert(set)
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET stable_lesson_set_digest = ? WHERE job_id = ?",
        arguments: [set.digest.rawValue, jobID]
      )
    }
    return set
  }

  /// A second armed job holding byte-identical lessons — and therefore the identical digest, which
  /// is what makes a digest-only identity check pass across jobs.
  func armSecondJob(holding set: LessonSet) throws -> Int64 {
    let other = try jobs.create(
      NewScheduledJob(
        ownerChatID: chatID,
        label: "other",
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
    _ = try TestLearningFixtures(writer: queue).seedArmedJob(jobID: other.id, now: now)
    try insert(try LessonSet.canonical(jobID: other.id, lessons: set.lessons))
    return other.id
  }

  func rebindJob(runID: Int64, to jobID: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE run_learning_bindings SET job_id = ? WHERE run_id = ?",
        arguments: [jobID, runID]
      )
    }
  }

  func fireBoundRun() throws -> ClaimedFire {
    guard case .fired(let fired) = try jobs.fireNow(jobID: jobID, now: now) else {
      throw StoreError.unexpected("job \(jobID) refused to fire")
    }
    return fired
  }

  /// An ordinary owner message on its own session: the shape that carries no binding at all.
  func inboundRun() throws -> (runID: Int64, sessionID: Int64, triggerMessageID: Int64) {
    let claim = try sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: chatID),
        chatID: chatID,
        userID: chatID,
        text: "hi",
        isEdited: false,
        ts: now
      )
    )
    return (
      try #require(claim.runID),
      try #require(claim.sessionID),
      try #require(claim.triggerMessageID)
    )
  }

  func runState(runID: Int64) throws -> RunState? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runID])
        .flatMap(RunState.init(rawValue:))
    }
  }

  func sessionIsTainted(sessionID: Int64) throws -> Bool {
    try queue.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT tainted FROM sessions WHERE id = ?",
        arguments: [sessionID]
      ) ?? false
    }
  }

  private func insert(_ set: LessonSet) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO lesson_sets(job_id, digest, schema_version, canonical_bytes,
            source, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          set.jobID,
          set.digest.rawValue,
          set.schemaVersion,
          set.canonicalBytes,
          LessonSetSource.reflectorCandidate.rawValue,
          EpochSecondCodec.epoch(now),
        ]
      )
    }
  }
}

// MARK: - Feedback Target Fixtures

private extension FeedbackTarget {
  var newTarget: NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: nonce,
      jobID: jobID,
      epoch: epoch,
      subjectKind: subjectKind,
      subjectDigest: subjectDigest,
      allowedActions: allowedActions,
      ownerUserID: ownerUserID,
      chatID: chatID,
      expiresAt: expiresAt
    )
  }
}

/// The real learning store with one fact removed: no lesson set ever resolves.
///
/// Everything else — the binding above all — stays the real row the fire wrote.
private struct UnresolvableLessonSets: ScheduledLearningStore {
  func sweepRetention(now: Date) throws(StoreError) -> RetentionSweepResult {
    try base.sweepRetention(now: now)
  }

  let base: ScheduledLearningStoreGRDB

  func applyTrialDecision(
    _ decision: TrialDecision,
    trial: LearningTrial,
    feedbackRevision: FeedbackRevision,
    now: Date
  ) throws(StoreError) -> DecisionReceipt? {
    try base.applyTrialDecision(
      decision,
      trial: trial,
      feedbackRevision: feedbackRevision,
      now: now
    )
  }

  func rollback(_ trigger: RollbackTrigger, now: Date) throws(StoreError) -> DecisionReceipt? {
    try base.rollback(trigger, now: now)
  }

  func commitPromotionReply(
    updateID: Int64,
    target: NewFeedbackTarget,
    chunks: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) -> PromotionReplyOutcome {
    try base.commitPromotionReply(updateID: updateID, target: target, chunks: chunks, now: now)
  }

  func currentPromotion(jobID: Int64) throws(StoreError) -> DecisionReceipt? {
    try base.currentPromotion(jobID: jobID)
  }

  func learningView(jobID: Int64?) throws(StoreError) -> [JobLearningView] {
    try base.learningView(jobID: jobID)
  }

  func applyReset(
    updateID: Int64,
    jobID: Int64,
    now: Date
  ) throws(StoreError) -> ConfirmedLearningResetResult {
    try base.applyReset(updateID: updateID, jobID: jobID, now: now)
  }

  func admitCandidate(
    digest: CandidateDigest,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome {
    try base.admitCandidate(digest: digest, redactor: redactor, now: now)
  }

  func approveCandidate(
    _ approval: CandidateApproval,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome {
    try base.approveCandidate(approval, redactor: redactor, now: now)
  }

  func editCandidate(
    _ edit: CandidateEdit,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome {
    try base.editCandidate(edit, redactor: redactor, now: now)
  }

  func commitCandidateReview(_ review: CandidateReviewNotice, now: Date) throws(StoreError) -> Bool
  { try base.commitCandidateReview(review, now: now) }

  func feedbackTarget(nonce: String) throws(StoreError) -> FeedbackTarget? {
    try base.feedbackTarget(nonce: nonce)
  }

  func consumeAndAppendEvent(_ tap: FeedbackTap, now: Date) throws(StoreError) -> FeedbackOutcome {
    try base.consumeAndAppendEvent(tap, now: now)
  }

  func consumeAndOpenChallenge(
    _ tap: FeedbackTap,
    prompt: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) -> FeedbackOutcome {
    try base.consumeAndOpenChallenge(tap, prompt: prompt, now: now)
  }

  func consumeChallenge(id: Int64, payload: String, now: Date) throws(StoreError) -> FeedbackOutcome
  { try base.consumeChallenge(id: id, payload: payload, now: now) }

  func liveChallenge(ownerUserID: Int64, chatID: Int64) throws(StoreError) -> FeedbackChallenge? {
    try base.liveChallenge(ownerUserID: ownerUserID, chatID: chatID)
  }

  func lessonSet(jobID: Int64, digest: LessonSetDigest) throws(StoreError) -> LessonSet? { nil }

  func binding(runID: Int64) throws(StoreError) -> RunLearningBinding? {
    try base.binding(runID: runID)
  }

  func openTrial(jobID: Int64) throws(StoreError) -> LearningTrial? {
    try base.openTrial(jobID: jobID)
  }

  func recomputeAssignment(runID: Int64, now: Date) throws(StoreError) -> AssignmentRecomputation {
    try base.recomputeAssignment(runID: runID, now: now)
  }

  func liveTrialIdentities() throws(StoreError) -> [LearningTrialIdentity] {
    try base.liveTrialIdentities()
  }

  func reconcileTrial(
    _ identity: LearningTrialIdentity,
    now: Date
  ) throws(StoreError) -> TrialReconciliationResult { try base.reconcileTrial(identity, now: now) }

  @discardableResult
  func settleFromLane(runID: Int64, now: Date) throws(StoreError) -> Bool {
    try base.settleFromLane(runID: runID, now: now)
  }

  func freezeCompatibility(runID: Int64, surface: RunSurface) throws(StoreError) {
    try base.freezeCompatibility(runID: runID, surface: surface)
  }

  func compatibility(runID: Int64) throws(StoreError) -> RunCompatibility? {
    try base.compatibility(runID: runID)
  }

  func unsealed(limit: Int) throws(StoreError) -> [Int64] { try base.unsealed(limit: limit) }

  @discardableResult
  func sealEvidence(runID: Int64, now: Date) throws(StoreError) -> SealOutcome {
    try base.sealEvidence(runID: runID, now: now)
  }

  func evidence(runID: Int64) throws(StoreError) -> SealedEvidence? {
    try base.evidence(runID: runID)
  }

  func prepareReflection(trigger: TriggerIdentity) throws(StoreError) -> ReflectionPreparation? {
    try base.prepareReflection(trigger: trigger)
  }

  func claimOperation(
    _ key: LearningOperationKey,
    now: Date
  ) throws(StoreError) -> ClaimedOperation? { try base.claimOperation(key, now: now) }

  func authorizeAndStartOperation(
    _ authorization: LearningAuthorization,
    now: Date
  ) throws(StoreError) -> AuthorizeOutcome {
    try base.authorizeAndStartOperation(authorization, now: now)
  }

  func finishOperation(_ result: LearningOperationResult, now: Date) throws(StoreError) -> Bool {
    try base.finishOperation(result, now: now)
  }

  func evaluation(runID: Int64) throws(StoreError) -> LearningEvaluation? {
    try base.evaluation(runID: runID)
  }

  func candidateArtifact(digest: CandidateDigest) throws(StoreError) -> CandidateArtifact? {
    try base.candidateArtifact(digest: digest)
  }

  @discardableResult
  func reconcileOperationsAtBoot(now: Date) throws(StoreError) -> OperationReconciliation {
    try base.reconcileOperationsAtBoot(now: now)
  }
}
