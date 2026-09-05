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
/// Substituting the job's current set — or running on lessons that belong to another job — would
/// evaluate a hypothesis the binding never froze, and every later decision reads that evidence.
@Suite struct PinnedLessonTests {
  @Test func aBoundRunNeverSubstitutesTheCurrentStableSet() async throws {
    // given — the job's stable pointer moved after this run was bound
    let env = try PinnedLessonEnvironment.make()
    let pinned = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()
    let promoted = try env.pinStableSet(["Report every heading."])

    // when
    try await env.runner.run(
      runId: fired.runId,
      sessionId: fired.sessionId,
      chatId: env.chatId,
      triggerMessageId: fired.triggerMessageId
    )

    // then — the frozen set reached the model; the newer one never did
    let sent = try #require(await env.provider.requests.first).renderedContext
    #expect(sent.contains(pinned.lessons[0]))
    #expect(sent.contains(promoted.lessons[0]) == false)
    #expect(try env.runState(runId: fired.runId) == .done)
  }

  @Test func pinnedLessonsTaintTheRunTheyAreAssembledInto() async throws {
    // given — an untainted session and a job whose bound run carries lessons
    let env = try PinnedLessonEnvironment.make()
    _ = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()

    // when
    try await env.runner.run(
      runId: fired.runId,
      sessionId: fired.sessionId,
      chatId: env.chatId,
      triggerMessageId: fired.triggerMessageId
    )

    // then — a model wrote those lessons, so the run leaves its session tainted
    #expect(try env.sessionIsTainted(sessionId: fired.sessionId))
  }

  @Test func aBindingThatNamesAnotherJobFailsTheRunBeforeDispatch() async throws {
    // given — a second job holding the identical lessons, so the digest alone still resolves
    let env = try PinnedLessonEnvironment.make()
    let pinned = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()
    let otherJobId = try env.armSecondJob(holding: pinned)
    try env.rebindJob(runId: fired.runId, to: otherJobId)

    // when
    try await env.runner.run(
      runId: fired.runId,
      sessionId: fired.sessionId,
      chatId: env.chatId,
      triggerMessageId: fired.triggerMessageId
    )

    // then — the run fails on the identity the digest cannot carry, before any provider call
    #expect(await env.provider.callCount == 0)
    #expect(try env.runState(runId: fired.runId) == .failed)
  }

  @Test func aRunWithNoBindingStillRunsWhileLearningIsArmed() async throws {
    // given — the inbound turn every armed daemon serves between fires
    let env = try PinnedLessonEnvironment.make()
    _ = try env.pinStableSet(["Report only price changes."])
    let inbound = try env.inboundRun()

    // when
    try await env.runner.run(
      runId: inbound.runId,
      sessionId: inbound.sessionId,
      chatId: env.chatId,
      triggerMessageId: inbound.triggerMessageId
    )

    // then — no binding, no lesson row, no failure
    let sent = try #require(await env.provider.requests.first).renderedContext
    #expect(sent.contains(ContextBuilder.lessonsLabel) == false)
    #expect(try env.runState(runId: inbound.runId) == .done)
  }

  @Test func aBindingWrittenBeforeTheFlagCameOffIsIgnored() async throws {
    // given — a run bound while learning was armed, resuming under a disarmed daemon
    let env = try PinnedLessonEnvironment.make(learning: { _ in
      nil
    })
    let pinned = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()

    // when
    try await env.runner.run(
      runId: fired.runId,
      sessionId: fired.sessionId,
      chatId: env.chatId,
      triggerMessageId: fired.triggerMessageId
    )

    // then — the flag is a kill switch: no row, no taint, and the run still completes
    let sent = try #require(await env.provider.requests.first).renderedContext
    #expect(sent.contains(pinned.lessons[0]) == false)
    #expect(try env.sessionIsTainted(sessionId: fired.sessionId) == false)
    #expect(try env.runState(runId: fired.runId) == .done)
  }

  @Test func anUnresolvablePinnedSetFailsTheRunBeforeDispatch() async throws {
    // given — the binding's set cannot be read back. The schema's composite foreign key keeps this
    // out of a real database, so the store is wrapped to produce the one fact under test.
    let env = try PinnedLessonEnvironment.make(learning: { store in
      UnresolvableLessonSets(base: store)
    })
    _ = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()

    // when
    try await env.runner.run(
      runId: fired.runId,
      sessionId: fired.sessionId,
      chatId: env.chatId,
      triggerMessageId: fired.triggerMessageId
    )

    // then — the run fails rather than answering with no lessons at all
    #expect(await env.provider.callCount == 0)
    #expect(try env.runState(runId: fired.runId) == .failed)
  }

  @Test func aResumeLoadsTheSamePinnedSetTheDispatchUsed() async throws {
    // given — a bound run already picked up, as an approval's continuation finds it. The suspend
    // choreography is elided: the pinned read depends on the run's binding, not on how it parked.
    let env = try PinnedLessonEnvironment.make()
    let pinned = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()
    _ = try env.runs.pickUp(runId: fired.runId, now: env.now)

    // when
    await env.runner.resume(
      runId: fired.runId,
      sessionId: fired.sessionId,
      chatId: env.chatId,
      contextBoundMessageId: fired.triggerMessageId
    )

    // then
    let sent = try #require(await env.provider.requests.first).renderedContext
    #expect(sent.contains(pinned.lessons[0]))
  }

  @Test func aCompletedBoundScheduledRunCommitsOneTargetAndOnlyFinalChunkKeyboard() async throws {
    // given — enough content to force multiple result chunks, with a deterministic opaque address
    let answer = String(repeating: "a", count: ReplySplitter.limit + 64)
    let env = try PinnedLessonEnvironment.make(
      responseContent: answer,
      makeFeedbackNonce: { "scheduled-feedback-nonce" }
    )
    _ = try env.pinStableSet(["Report only price changes."])
    let fired = try env.fireBoundRun()

    // when
    try await env.runner.run(
      runId: fired.runId,
      sessionId: fired.sessionId,
      chatId: env.chatId,
      triggerMessageId: fired.triggerMessageId
    )

    // then — the runner derives the exact run target and attaches its keyboard only at the end
    let target = try #require(try env.learning.feedbackTarget(nonce: "scheduled-feedback-nonce"))
    #expect(target.jobId == env.jobId)
    #expect(target.epoch == LearningEpoch(1))
    #expect(target.subjectKind == .run)
    #expect(target.subjectDigest == String(fired.runId))
    #expect(target.allowedActions == [.resultUseful, .resultNotUseful, .resultCorrection])
    #expect(target.ownerUserId == env.chatId)
    #expect(target.chatId == env.chatId)
    #expect(target.expiresAt == env.now.addingTimeInterval(EvidenceWindow.maximumAge))
    let chunks = try OutboxStoreGRDB(writer: env.queue).pendingOutbound()
    #expect(chunks.count > 1)
    #expect(chunks.dropLast().allSatisfy { $0.replyMarkup == nil })
    #expect(chunks.last?.replyMarkup == LearningNotices.resultKeyboard(target: target.newTarget))
  }
}

// MARK: - Fixture

private extension ChatRequest {
  /// The whole assembled prompt as the provider receives it.
  var renderedContext: String {
    messages.map(\.content.text).joined(separator: "\n")
  }
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
  let jobId: Int64
  let chatId: Int64
  let now: Date

  /// - Parameter learning: what the runner reads pinned lessons through, given the real store.
  ///   Returning nil is a disarmed daemon; wrapping it is how a test reaches a state the schema's
  ///   own foreign key keeps out of the database.
  static func make(
    responseContent: String = "done",
    makeFeedbackNonce: @escaping @Sendable () -> String = { OpaqueNonce.generate() },
    learning wiring: (ScheduledLearningStoreGRDB) -> (any ScheduledLearningStore)? = { store in
      store
    }
  ) throws -> PinnedLessonEnvironment {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let chatId: Int64 = 777
    let now = Date(timeIntervalSince1970: 1_782_000_600)

    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatId: chatId,
        label: "digest",
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    _ = try learning.armJob(jobId: job.id, now: now)

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
      budget: .default,
      contextBuilder: ContextBuilder(
        systemPrompt: SystemPrompt.minimal,
        proactiveSystemPrompt: "proactive policy",
        workspace: EmptyWorkspace(),
        memoryStore: EmptyMemoryStore(),
        retriever: EmptyRetriever(),
        budget: .default,
        now: { now }
      ),
      imageCache: ImageCache(),
      notifyOutbox: {},
      now: { now },
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
      jobId: job.id,
      chatId: chatId,
      now: now
    )
  }

  /// Stores a set for this job and makes it the job's stable pointer, which is what the next fire
  /// binds against.
  func pinStableSet(_ lessons: [String]) throws -> LessonSet {
    let set = try LessonSet.canonical(jobId: jobId, lessons: lessons)
    try insert(set)
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET stable_lesson_set_digest = ? WHERE job_id = ?",
        arguments: [set.digest.rawValue, jobId]
      )
    }
    return set
  }

  /// A second armed job holding byte-identical lessons — and therefore the identical digest, which
  /// is what makes a digest-only identity check pass across jobs.
  func armSecondJob(holding set: LessonSet) throws -> Int64 {
    let other = try jobs.create(
      NewScheduledJob(
        ownerChatId: chatId,
        label: "other",
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
    _ = try learning.armJob(jobId: other.id, now: now)
    try insert(try LessonSet.canonical(jobId: other.id, lessons: set.lessons))
    return other.id
  }

  func rebindJob(runId: Int64, to jobId: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE run_learning_bindings SET job_id = ? WHERE run_id = ?",
        arguments: [jobId, runId]
      )
    }
  }

  func fireBoundRun() throws -> ClaimedFire {
    guard case .fired(let fired) = try jobs.fireNow(jobId: jobId, now: now) else {
      throw StoreError.unexpected("job \(jobId) refused to fire")
    }
    return fired
  }

  /// An ordinary owner message on its own session: the shape that carries no binding at all.
  func inboundRun() throws -> (runId: Int64, sessionId: Int64, triggerMessageId: Int64) {
    let claim = try sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: chatId),
        chatId: chatId,
        userId: chatId,
        text: "hi",
        isEdited: false,
        ts: now
      )
    )
    return (
      try #require(claim.runId),
      try #require(claim.sessionId),
      try #require(claim.triggerMessageId)
    )
  }

  func runState(runId: Int64) throws -> RunState? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
        .flatMap(RunState.init(rawValue:))
    }
  }

  func sessionIsTainted(sessionId: Int64) throws -> Bool {
    try queue.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT tainted FROM sessions WHERE id = ?",
        arguments: [sessionId]
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
          set.jobId,
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

private extension FeedbackTarget {
  var newTarget: NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: nonce,
      jobId: jobId,
      epoch: epoch,
      subjectKind: subjectKind,
      subjectDigest: subjectDigest,
      allowedActions: allowedActions,
      ownerUserId: ownerUserId,
      chatId: chatId,
      expiresAt: expiresAt
    )
  }
}

/// The real learning store with one fact removed: no lesson set ever resolves. Everything else
/// — the binding above all — stays the real row the fire wrote.
private struct UnresolvableLessonSets: ScheduledLearningStore {
  let base: ScheduledLearningStoreGRDB

  func learningView(jobId: Int64?) throws(StoreError) -> [JobLearningView] {
    try base.learningView(jobId: jobId)
  }

  func applyReset(
    updateId: Int64,
    jobId: Int64,
    now: Date
  ) throws(StoreError) -> ConfirmedLearningResetResult {
    try base.applyReset(updateId: updateId, jobId: jobId, now: now)
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

  func commitCandidateReview(
    _ review: CandidateReviewNotice,
    now: Date
  ) throws(StoreError) -> Bool {
    try base.commitCandidateReview(review, now: now)
  }

  func createTargets(
    _ targets: [NewFeedbackTarget],
    chunks: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) {
    try base.createTargets(targets, chunks: chunks, now: now)
  }

  func feedbackTarget(nonce: String) throws(StoreError) -> FeedbackTarget? {
    try base.feedbackTarget(nonce: nonce)
  }

  func consumeAndAppendEvent(
    _ tap: FeedbackTap,
    now: Date
  ) throws(StoreError) -> FeedbackOutcome {
    try base.consumeAndAppendEvent(tap, now: now)
  }

  func consumeAndOpenChallenge(
    _ tap: FeedbackTap,
    prompt: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) -> FeedbackOutcome {
    try base.consumeAndOpenChallenge(tap, prompt: prompt, now: now)
  }

  func consumeChallenge(
    id: Int64,
    payload: String,
    now: Date
  ) throws(StoreError) -> FeedbackOutcome {
    try base.consumeChallenge(id: id, payload: payload, now: now)
  }

  func liveChallenge(
    ownerUserId: Int64,
    chatId: Int64
  ) throws(StoreError) -> FeedbackChallenge? {
    try base.liveChallenge(ownerUserId: ownerUserId, chatId: chatId)
  }

  func lessonSet(jobId: Int64, digest: LessonSetDigest) throws(StoreError) -> LessonSet? {
    nil
  }

  func armJob(jobId: Int64, now: Date) throws(StoreError) -> JobLearningState {
    try base.armJob(jobId: jobId, now: now)
  }

  func binding(runId: Int64) throws(StoreError) -> RunLearningBinding? {
    try base.binding(runId: runId)
  }

  func openTrial(jobId: Int64) throws(StoreError) -> LearningTrial? {
    try base.openTrial(jobId: jobId)
  }

  func recomputeAssignment(
    runId: Int64,
    now: Date
  ) throws(StoreError) -> AssignmentRecomputation {
    try base.recomputeAssignment(runId: runId, now: now)
  }

  func liveTrialIdentities() throws(StoreError) -> [LearningTrialIdentity] {
    try base.liveTrialIdentities()
  }

  func reconcileTrial(
    _ identity: LearningTrialIdentity,
    now: Date
  ) throws(StoreError) -> TrialReconciliationResult {
    try base.reconcileTrial(identity, now: now)
  }

  func settlement(runId: Int64) throws(StoreError) -> RunSettlement? {
    try base.settlement(runId: runId)
  }

  @discardableResult
  func settleFromLane(runId: Int64, now: Date) throws(StoreError) -> Bool {
    try base.settleFromLane(runId: runId, now: now)
  }

  func freezeCompatibility(runId: Int64, surface: RunSurface) throws(StoreError) {
    try base.freezeCompatibility(runId: runId, surface: surface)
  }

  func compatibility(runId: Int64) throws(StoreError) -> RunCompatibility? {
    try base.compatibility(runId: runId)
  }

  func unsealed(limit: Int) throws(StoreError) -> [Int64] {
    try base.unsealed(limit: limit)
  }

  @discardableResult
  func sealEvidence(runId: Int64, now: Date) throws(StoreError) -> SealOutcome {
    try base.sealEvidence(runId: runId, now: now)
  }

  func evidence(runId: Int64) throws(StoreError) -> SealedEvidence? {
    try base.evidence(runId: runId)
  }

  func prepareReflection(
    trigger: TriggerIdentity
  ) throws(StoreError) -> ReflectionPreparation? {
    try base.prepareReflection(trigger: trigger)
  }

  func claimOperation(
    _ key: LearningOperationKey,
    now: Date
  ) throws(StoreError) -> ClaimedOperation? {
    try base.claimOperation(key, now: now)
  }

  func authorizeAndStartOperation(
    _ authorization: LearningAuthorization,
    now: Date
  ) throws(StoreError) -> AuthorizeOutcome {
    try base.authorizeAndStartOperation(authorization, now: now)
  }

  func finishOperation(
    _ result: LearningOperationResult,
    now: Date
  ) throws(StoreError) -> Bool {
    try base.finishOperation(result, now: now)
  }

  func evaluation(runId: Int64) throws(StoreError) -> LearningEvaluation? {
    try base.evaluation(runId: runId)
  }

  func candidateArtifact(digest: CandidateDigest) throws(StoreError) -> CandidateArtifact? {
    try base.candidateArtifact(digest: digest)
  }

  @discardableResult
  func reconcileOperationsAtBoot(now: Date) throws(StoreError) -> OperationReconciliation {
    try base.reconcileOperationsAtBoot(now: now)
  }
}
