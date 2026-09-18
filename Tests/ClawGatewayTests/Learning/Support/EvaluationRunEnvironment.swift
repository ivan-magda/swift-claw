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
  static let chatID: Int64 = 777

  let queue: DatabaseQueue
  let jobs: ScheduledJobStoreGRDB
  let runs: RunStoreGRDB
  let learning: ScheduledLearningStoreGRDB
  let provider: SequenceProvider
  let authorizing: RecordingLearningStore
  let runner: LearningOperationRunner
  let jobID: Int64
  let sessionID: Int64
  let runID: Int64
  let now: Date

  struct UsageRow: Equatable {
    let model: String
    let runID: Int64?
    let jobID: Int64?
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
    followingReplies: [String] = [],
    repeatable: Bool = false,
    sealsEvidence: Bool = true,
    beforeResponse: @escaping @Sendable () async -> Void = {},
    finalOutput: String = EvaluationRunEnvironment.defaultFinalOutput,
    secretValues: [String] = [],
    proactivePerDayUSD: Double = RunBudget.default.proactivePerDayUSD,
    primaryFailure: (any Error & Sendable)? = nil,
    supersedeAuthorization: Bool = false,
    logger: Logger = TestLog.silent
  ) throws -> EvaluationRunEnvironment {
    let queue = try TestDatabase.make()
    let now = Date(timeIntervalSince1970: 1_782_000_600)

    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatID: chatID,
        label: "digest",
        prompt: "Check the page for material changes.",
        recurrence: repeatable ? SchedulingRuleFixtures.weekdayEnvelope(zone: .gmt) : nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    _ = try TestLearningFixtures(writer: queue).seedArmedJob(jobID: job.id, now: now)
    let runs = RunStoreGRDB(writer: queue)

    let fired = try fire(jobs, jobID: job.id, now: now)
    _ = try runs.pickUp(runID: fired.runID, now: now)
    try learning.freezeCompatibility(
      runID: fired.runID,
      surface: RunSurface(
        toolCatalogDigest: "tools-v1",
        policyVersion: "pv16",
        skillSetDigest: "skills-v1",
        configuredRoute: primaryRoute
      )
    )
    _ = try runs.commitAssistantTurn(
      answeredTurn(runID: fired.runID, sessionID: fired.sessionID, finalOutput: finalOutput),
      now: now
    )
    if sealsEvidence {
      _ = try learning.sealEvidence(runID: fired.runID, now: now)
    }

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
      }
      ?? SequenceProvider(
        [answer]
          + followingReplies.map { text in
            ChatResponse(
              content: text,
              finishReason: "stop",
              usage: ChatUsage(promptTokens: 100, completionTokens: 30, totalTokens: 130),
              costFromProvider: replyCostUSD
            )
          },
        beforeResponse: beforeResponse
      )
    let fallback = SequenceProvider(primaryFailure == nil ? [] : [answer])
    let roster = ProviderRoster(
      primary: LearningRunFixtures.routeBinding(provider: primary, reference: primaryRoute),
      fallback: LearningRunFixtures.routeBinding(provider: fallback, reference: fallbackRoute)
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
        budget: LearningRunFixtures.budget(proactivePerDayUSD: proactivePerDayUSD),
        costResolver: CostResolver(
          priceTable: .empty,
          referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
        ),
        redactor: SecretRedactor(secretValues: secretValues),
        logger: logger
      ),
      jobID: job.id,
      sessionID: fired.sessionID,
      runID: fired.runID,
      now: now
    )
  }
}

// MARK: - Operation Columns

extension EvaluationRunEnvironment {
  /// Rebuilt from the production constants the runner itself keys on, so a runner that claimed
  /// under another prompt, schema or rubric version resolves to no row at all.
  func operationID() throws -> LearningOperationID {
    guard let evidence = try learning.evidence(runID: runID) else {
      throw StoreError.unexpected("run \(runID) sealed no evidence to evaluate")
    }
    let key = LearningOperationKey(
      jobID: jobID,
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
        arguments: [runID]
      )
    }
  }

  func runUsage() throws -> [UsageRow] {
    try usageRows(where: "run_id = \(runID)")
  }

  func learningUsage() throws -> [UsageRow] {
    try usageRows(where: "learning_operation_id IS NOT NULL")
  }
}

// MARK: - Fixture Plumbing

private extension EvaluationRunEnvironment {
  static func fire(_ jobs: ScheduledJobStoreGRDB, jobID: Int64, now: Date) throws -> ClaimedFire {
    guard case .fired(let fired) = try jobs.fireNow(jobID: jobID, now: now) else {
      throw StoreError.unexpected("job \(jobID) refused to fire")
    }
    return fired
  }

  static func answeredTurn(runID: Int64, sessionID: Int64, finalOutput: String) -> AssistantTurn {
    AssistantTurn(
      runID: runID,
      sessionID: sessionID,
      chatID: chatID,
      content: finalOutput,
      usage: usageFixture(sessionID: sessionID, runID: runID, model: primaryRoute),
      chunks: [
        OutboxChunk(
          stepIndex: 0,
          chatID: chatID,
          payload: finalOutput,
          payloadHash: ContentHash.fnv1a(finalOutput)
        ),
      ]
    )
  }

  func operationColumn(_ column: String) throws -> String? {
    let id = try operationID()
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
      ).map { row in
        UsageRow(
          model: row["model"],
          runID: row["run_id"],
          jobID: row["learning_job_id"],
          tokens: row["tokens"],
          costUSD: row["cost_usd"],
          costSource: row["cost_source"]
        )
      }
    }
  }
}

extension EvaluationRunEnvironment {
  func settledBoundRun(at date: Date? = nil, toolCatalog: String = "tools-v1") throws -> Int64 {
    let instant = date ?? now
    let fired = try Self.fire(jobs, jobID: jobID, now: instant)
    _ = try runs.pickUp(runID: fired.runID, now: instant)
    try learning.freezeCompatibility(
      runID: fired.runID,
      surface: RunSurface(
        toolCatalogDigest: toolCatalog,
        policyVersion: "pv16",
        skillSetDigest: "skills-v1",
        configuredRoute: Self.primaryRoute
      )
    )
    _ = try runs.commitAssistantTurn(
      Self.answeredTurn(
        runID: fired.runID,
        sessionID: fired.sessionID,
        finalOutput: Self.defaultFinalOutput
      ),
      now: instant
    )
    return fired.runID
  }
}

extension EvaluationRunEnvironment {
  func candidateTargets() throws -> [FeedbackTarget] {
    let nonces = try queue.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT nonce FROM feedback_targets WHERE subject_kind = ?",
        arguments: [FeedbackSubjectKind.candidate.rawValue]
      )
    }
    return try nonces.compactMap { nonce in
      try learning.feedbackTarget(nonce: nonce)
    }
  }
}

extension EvaluationRunEnvironment {
  func evaluationAuditCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM audit_events WHERE action = ? AND run_id = ?",
        arguments: [AuditAction.learningEvaluated.rawValue, runID]
      ) ?? 0
    }
  }
}
