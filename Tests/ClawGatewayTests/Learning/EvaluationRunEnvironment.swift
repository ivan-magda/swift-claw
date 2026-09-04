import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Logging

@testable import ClawData
@testable import ClawGateway

/// A migrated database holding one armed job whose bound run has answered, settled and sealed as
/// task evidence — the exact state the evaluator is allowed to read — plus a two-route roster the
/// runner drives and the raw columns its commit is judged by.
struct EvaluationRunEnvironment {
  static let primaryRoute = "openai-compatible/primary-model"
  static let fallbackRoute = "openai-compatible/fallback-model"
  static let noIssueReply = #"{"schema_version":1,"outcome":"no_issue","issue_codes":[]}"#
  /// The run's own answer. Named because a test asserts it reached the evaluator, and the carrier
  /// is the only thing that could have carried it there.
  static let defaultFinalOutput = "The price changed from 10 to 12."
  static let chatId: Int64 = 777

  let queue: DatabaseQueue
  let jobs: ScheduledJobStoreGRDB
  let runs: RunStoreGRDB
  let learning: ScheduledLearningStoreGRDB
  let provider: SequenceProvider
  let authorizing: RecordingLearningStore
  let runner: LearningOperationRunner
  let jobId: Int64
  let sessionId: Int64
  let runId: Int64
  let now: Date

  struct UsageRow: Equatable {
    let model: String
    let runId: Int64?
    let jobId: Int64?
    let tokens: Int
    let costUSD: Double
    let costSource: String
  }

  /// What the scripted evaluator reply bills. Named so the spend assertions read against the
  /// provider's own numbers rather than against constants that could drift apart from the script.
  static let replyPromptTokens = 300
  static let replyCompletionTokens = 40
  static let replyCostUSD = 0.0021

  static func make(
    reply: String,
    finalOutput: String = EvaluationRunEnvironment.defaultFinalOutput,
    secretValues: [String] = [],
    proactivePerDayUSD: Double = RunBudget.default.proactivePerDayUSD,
    primaryFailure: (any Error & Sendable)? = nil,
    supersedeAuthorization: Bool = false,
    logger: Logger = TestLog.silent
  ) throws -> EvaluationRunEnvironment {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let now = Date(timeIntervalSince1970: 1_782_000_600)

    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatId: chatId,
        label: "digest",
        prompt: "Check the page for material changes.",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    _ = try learning.armJob(jobId: job.id, now: now)
    let runs = RunStoreGRDB(writer: queue)

    let fired = try fire(jobs, jobId: job.id, now: now)
    _ = try runs.pickUp(runId: fired.runId, now: now)
    try learning.freezeCompatibility(
      runId: fired.runId,
      surface: RunSurface(
        toolCatalogDigest: "tools-v1",
        policyVersion: "pv16",
        skillSetDigest: "skills-v1",
        configuredRoute: primaryRoute
      )
    )
    _ = try runs.commitAssistantTurn(
      answeredTurn(
        runId: fired.runId,
        sessionId: fired.sessionId,
        finalOutput: finalOutput
      ),
      now: now
    )
    _ = try learning.sealEvidence(runId: fired.runId, now: now)

    let answer = ChatResponse(
      content: reply,
      finishReason: "stop",
      usage: ChatUsage(
        promptTokens: replyPromptTokens,
        completionTokens: replyCompletionTokens,
        totalTokens: replyPromptTokens + replyCompletionTokens
      ),
      costFromProvider: replyCostUSD
    )
    let primary =
      primaryFailure.map { failure in
        SequenceProvider([], then: failure)
      } ?? SequenceProvider([answer])
    let fallback = SequenceProvider(primaryFailure == nil ? [] : [answer])
    let roster = ProviderRoster(
      primary: routeBinding(provider: primary, reference: primaryRoute),
      fallback: routeBinding(provider: fallback, reference: fallbackRoute)
    )

    let authorizing = RecordingLearningStore(base: learning, supersedes: supersedeAuthorization)
    return EvaluationRunEnvironment(
      queue: queue,
      jobs: jobs,
      runs: runs,
      learning: learning,
      provider: primary,
      authorizing: authorizing,
      runner: LearningOperationRunner(
        learning: authorizing,
        jobs: jobs,
        roster: roster,
        budget: budget(proactivePerDayUSD: proactivePerDayUSD),
        costResolver: CostResolver(
          priceTable: .empty,
          referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
        ),
        redactor: SecretRedactor(secretValues: secretValues),
        logger: logger
      ),
      jobId: job.id,
      sessionId: fired.sessionId,
      runId: fired.runId,
      now: now
    )
  }
}

// MARK: - Operation Columns

extension EvaluationRunEnvironment {
  /// Rebuilt from the production constants the runner itself keys on, so a runner that claimed
  /// under another prompt, schema or rubric version resolves to no row at all.
  func operationId() throws -> LearningOperationID {
    guard let evidence = try learning.evidence(runId: runId) else {
      throw StoreError.unexpected("run \(runId) sealed no evidence to evaluate")
    }
    let key = LearningOperationKey(
      jobId: jobId,
      epoch: evidence.epoch,
      phase: .evaluator,
      sourceDigest: evidence.digest.rawValue,
      promptVersion: EvaluatorPrompt.v1.version,
      schemaVersion: EvaluatorOutput.currentSchemaVersion,
      rubricVersion: EvaluatorRubric.v1.version
    )
    return LearningOperationID(key: key.digest, attemptGeneration: 1)
  }

  func operationState() throws -> LearningOperationState? {
    try operationColumn("state").flatMap(LearningOperationState.init(rawValue:))
  }

  func failureCode() throws -> LearningOperationFailure? {
    try operationColumn("failure_code").flatMap(LearningOperationFailure.init(rawValue:))
  }

  func operationRoute() throws -> String? {
    try operationColumn("route")
  }

  func evaluationRowCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM learning_evaluations") ?? -1
    }
  }

  func evaluatorRoute() throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT evaluator_route FROM run_compatibility WHERE run_id = ?",
        arguments: [runId]
      )
    }
  }

  func runUsage() throws -> [UsageRow] {
    try usageRows(where: "run_id = \(runId)")
  }

  func learningUsage() throws -> [UsageRow] {
    try usageRows(where: "learning_operation_id IS NOT NULL")
  }
}

// MARK: - Fixture Plumbing

private extension EvaluationRunEnvironment {
  static func fire(
    _ jobs: ScheduledJobStoreGRDB,
    jobId: Int64,
    now: Date
  ) throws -> ClaimedFire {
    guard case .fired(let fired) = try jobs.fireNow(jobId: jobId, now: now) else {
      throw StoreError.unexpected("job \(jobId) refused to fire")
    }
    return fired
  }

  static func answeredTurn(runId: Int64, sessionId: Int64, finalOutput: String) -> AssistantTurn {
    AssistantTurn(
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      content: finalOutput,
      usage: usageFixture(sessionId: sessionId, runId: runId, model: primaryRoute),
      chunks: [
        OutboxChunk(
          stepIndex: 0,
          chatId: chatId,
          payload: finalOutput,
          payloadHash: ContentHash.fnv1a(finalOutput)
        )
      ]
    )
  }

  static func routeBinding(provider: any LLMProvider, reference: String) -> LLMRouteBinding {
    LLMRouteBinding(
      provider: provider,
      wireModel: reference,
      configuredReference: reference,
      costPolicy: .metered,
      reservationPolicy: .textOnly
    )
  }

  static func budget(proactivePerDayUSD: Double) -> RunBudget {
    let base = RunBudget.default
    return RunBudget(
      maxInputTokens: base.maxInputTokens,
      maxOutputTokens: base.maxOutputTokens,
      wallClockDeadlineSeconds: base.wallClockDeadlineSeconds,
      retryBudget: base.retryBudget,
      perRunUSD: base.perRunUSD,
      perDayUSD: base.perDayUSD,
      proactivePerDayUSD: proactivePerDayUSD,
      referenceUSDPerToken: base.referenceUSDPerToken
    )
  }

  func operationColumn(_ column: String) throws -> String? {
    let id = try operationId()
    return try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT \(column) FROM learning_operations WHERE operation_id = ?",
        arguments: [id.rawValue]
      )
    }
  }

  func usageRows(where predicate: String) throws -> [UsageRow] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT model, run_id, learning_job_id, cost_usd, cost_source,
            prompt_tokens + completion_tokens AS tokens
          FROM provider_usage WHERE \(predicate) ORDER BY id
          """
      )
      .map { row in
        UsageRow(
          model: row["model"],
          runId: row["run_id"],
          jobId: row["learning_job_id"],
          tokens: row["tokens"],
          costUSD: row["cost_usd"],
          costSource: row["cost_source"]
        )
      }
    }
  }
}

// MARK: - Authorization Decorator

/// The real store with its authorization hop observed, and optionally answered. Everything else
/// stays the real row, so the operation the runner claimed is genuinely there to inspect.
///
/// Lock-guarded, not an actor: `ScheduledLearningStore` is synchronous — the GRDB stores are
/// `Sendable` wrappers that lean on GRDB's own serialization — and an actor cannot satisfy a
/// synchronous requirement.
final class RecordingLearningStore: ScheduledLearningStore, @unchecked Sendable {
  private let lock = NSLock()
  private let base: ScheduledLearningStoreGRDB
  private let supersedes: Bool
  private var presented: [LearningAuthorization] = []

  init(base: ScheduledLearningStoreGRDB, supersedes: Bool = false) {
    self.base = base
    self.supersedes = supersedes
  }

  /// Every authorization the runner presented, in order.
  var authorizations: [LearningAuthorization] {
    lock.lock()
    defer { lock.unlock() }
    return presented
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

  func authorizeAndStartOperation(
    _ authorization: LearningAuthorization,
    now: Date
  ) throws(StoreError) -> AuthorizeOutcome {
    lock.lock()
    presented.append(authorization)
    lock.unlock()
    guard supersedes == false else {
      return .superseded
    }
    return try base.authorizeAndStartOperation(authorization, now: now)
  }

  func armJob(jobId: Int64, now: Date) throws(StoreError) -> JobLearningState {
    try base.armJob(jobId: jobId, now: now)
  }

  func lessonSet(jobId: Int64, digest: LessonSetDigest) throws(StoreError) -> LessonSet? {
    try base.lessonSet(jobId: jobId, digest: digest)
  }

  func binding(runId: Int64) throws(StoreError) -> RunLearningBinding? {
    try base.binding(runId: runId)
  }

  func openTrial(jobId: Int64) throws(StoreError) -> LearningTrial? {
    try base.openTrial(jobId: jobId)
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

  func claimOperation(
    _ key: LearningOperationKey,
    now: Date
  ) throws(StoreError) -> ClaimedOperation? {
    try base.claimOperation(key, now: now)
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

  @discardableResult
  func reconcileOperationsAtBoot(now: Date) throws(StoreError) -> OperationReconciliation {
    try base.reconcileOperationsAtBoot(now: now)
  }
}
