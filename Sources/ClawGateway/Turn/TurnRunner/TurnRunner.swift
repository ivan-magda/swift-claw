import ClawAgent
import ClawCore
import Foundation
import Logging

/// Injected behind a protocol so the router/poller tests stay decoupled from the real provider.
public protocol TurnDispatching: Sendable {
  func run(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64
  ) async throws
  /// Continues a run the approval waiter already flipped AWAITING_APPROVAL → RUNNING: no pick-up,
  /// context bound to the filled observation row, budget counters carried over.
  func resume(runId: Int64, sessionId: Int64, chatId: Int64, contextBoundMessageId: Int64) async
}

extension TurnDispatching {
  public func resume(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    contextBoundMessageId: Int64
  ) async {}
}

/// Picks up a durable PENDING run, assembles its trigger-bounded context, executes the agent, and
/// persists the outcome.
public struct TurnRunner: TurnDispatching {
  let sessionMessages: any SessionMessageStore
  let runs: any RunStore
  let usageStore: any UsageStore

  let audit: any AuditLog
  private let agent: AgentRuntime
  private let budget: RunBudget
  let contextBuilder: ContextBuilder
  package let imageCache: ImageCache
  /// Pokes the outbox dispatcher to drain after a commit. A no-op until the dispatcher is wired.
  let notifyOutbox: @Sendable () -> Void
  /// Post-commit daily kill-switch and its best-effort owner-DM delivery port.
  let breaker: BudgetBreaker?
  let delivery: (any MessageDelivery)?
  /// The config-resolved owner DM for process-wide notices raised by a group turn.
  let ownerChatId: Int64?
  /// The turn's clock. Sourcing the budget "today" window from an injected now (defaulting to the
  /// real clock) keeps the proactive/global daily-spend boundary deterministic under test — the
  /// same seam ContextBuilder/MessageRouter/SchedulerService already use.
  let now: @Sendable () -> Date

  let logger: Logger

  /// Freezes the learning compatibility surface of a bound run, at pickup, while every value in it
  /// is still current. Injected rather than assembled here: the tool catalog, the skills root and
  /// the resolved route all live at the composition root, and a run that is not bound freezes
  /// nothing. Inert when learning is disarmed.
  private let freezeLearningSurface: @Sendable (_ runId: Int64, _ policyVersion: String) -> Void

  /// Reads the lesson set a bound run froze at its fire. Nil while learning is disarmed, which is
  /// the same turn a run with no binding gets: no lesson row, no lesson taint. Disarming has to
  /// reach this seam, not only the fire path — a run bound before the flag came off can still be
  /// parked on an approval and resume afterwards.
  let learning: (any ScheduledLearningStore)?
  /// Generates the opaque address embedded in a completed result's feedback keyboard.
  let makeFeedbackNonce: @Sendable () -> String

  /// The lane-hold seam: after the suspend commit, `park` awaits the durable approval's
  /// resolution.
  let parker: any ApprovalParking
  /// Seconds a suspended approval stays live (ARCHITECTURE.md §11). Injected so the commit's
  /// `expires_ts` is deterministic under test.
  let approvalExpirySeconds: Int

  package init(
    sessionMessages: any SessionMessageStore,
    runs: any RunStore,
    usageStore: any UsageStore,
    audit: any AuditLog,
    agent: AgentRuntime,
    budget: RunBudget,
    contextBuilder: ContextBuilder,
    imageCache: ImageCache,
    notifyOutbox: @escaping @Sendable () -> Void,
    breaker: BudgetBreaker? = nil,
    delivery: (any MessageDelivery)? = nil,
    ownerChatId: Int64? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    freezeLearningSurface: @escaping @Sendable (Int64, String) -> Void = { _, _ in },
    learning: (any ScheduledLearningStore)? = nil,
    makeFeedbackNonce: @escaping @Sendable () -> String = { OpaqueNonce.generate() },
    // No default: an ask-tier suspend parks the lane on this seam, and a composition site that
    // silently fell back to an inert parker (whose private coordinator no resolver ever signals)
    // would hold that lane forever. Every caller chooses its parker explicitly.
    parker: any ApprovalParking,
    approvalExpirySeconds: Int,
    logger: Logger
  ) {
    self.sessionMessages = sessionMessages
    self.runs = runs
    self.usageStore = usageStore

    self.audit = audit
    self.agent = agent
    self.budget = budget
    self.contextBuilder = contextBuilder
    self.imageCache = imageCache

    self.notifyOutbox = notifyOutbox
    self.breaker = breaker
    self.delivery = delivery
    self.ownerChatId = ownerChatId

    self.now = now
    self.freezeLearningSurface = freezeLearningSurface
    self.learning = learning
    self.makeFeedbackNonce = makeFeedbackNonce
    self.parker = parker
    self.approvalExpirySeconds = approvalExpirySeconds
    self.logger = logger
  }

  public func run(  // swiftlint:disable:this function_body_length
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64
  ) async throws {
    guard !Task.isCancelled else {
      return
    }

    let now = now()
    // The fingerprint is computed from the same builder inputs `assemble` will use and
    // stamped in the same UPDATE that flips PENDING→RUNNING, so an approval this run creates binds
    // to the exact prompt/tool/config surface in force at run start.
    let policyVersion = contextBuilder.currentPolicyVersion()
    guard let origin = try runs.pickUp(runId: runId, policyVersion: policyVersion, now: now) else {
      logger.debug("run \(runId) was not pending at pickup; skipping turn")
      return
    }
    // Frozen here rather than read back at sealing: this run's evidence has to be filed under the
    // surface it actually ran on, and the skills, the tool catalog and the route can all move
    // before the sealer reaches it.
    freezeLearningSurface(runId, policyVersion)

    guard !Task.isCancelled else {
      return
    }

    let inputs: TurnInputs
    do {
      inputs = try loadTurnInputs(
        runId: runId,
        sessionId: sessionId,
        boundMessageId: triggerMessageId,
        origin: origin,
        at: now,
        images: await cachedImages(sessionId: sessionId)
      )
    } catch StoreError.diskFull {
      throw StoreError.diskFull
    } catch {
      logger.error("context build failed for run \(runId): \(error)")
      try commitContextUnavailable(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        setTainted: false,
        at: Date()
      )
      return
    }

    // Real session taint: the gate reads `(session ∪ run)`, so a session already tainted by a
    // prior turn keeps the exfil gate armed from this run's very first tool call.
    let mode = SessionKey.mode(from: inputs.snapshot.sessionKey)
    let outcome = try await agent.runTurn(
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      buildResult: inputs.buildResult,
      sessionTainted: inputs.snapshot.isTainted,
      hasPinnedLessons: inputs.buildResult.hasPinnedLessons,
      sessionHasPrivateData: inputs.snapshot.hasPrivateData,
      todayTokens: inputs.todayTokens,
      todayUSD: inputs.todayUSD,
      origin: origin,
      proactiveTodayUSD: inputs.proactiveTodayUSD,
      mode: mode,
      threadId: SessionKey.threadId(from: inputs.snapshot.sessionKey)
    )

    try await commit(
      outcome,
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      mode: mode,
      ownerNotices: inputs.buildResult.ownerNotices,
      origin: origin
    )
  }

  /// The post-approval continuation, identical to `run` except: no `pickUp` (the waiter already
  /// flipped AWAITING_APPROVAL → RUNNING via the executor), the context bound is the FILLED
  /// observation row's message id (the trigger id would exclude the partial exchange), and
  /// `runTurn` is seeded
  /// with the run's carried-over budget counters. Non-throwing: it runs on the session lane inside
  /// the waiter's `park`, so every failure resolves in-band (a build/turn failure fails the run so
  /// the lane frees).
  public func resume(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    contextBoundMessageId: Int64
  ) async {
    guard !Task.isCancelled else {
      return
    }

    guard let origin = resumeOrigin(runId: runId) else {
      return
    }

    let inputs: TurnInputs
    let carryOver: ResumeUsage
    do {
      carryOver = try runs.resumeUsage(runId: runId)
      inputs = try loadTurnInputs(
        runId: runId,
        sessionId: sessionId,
        boundMessageId: contextBoundMessageId,
        origin: origin,
        at: now(),
        images: await cachedImages(sessionId: sessionId)
      )
    } catch {
      failResume(runId: runId, stage: .contextBuild, error: error)
      return
    }

    let mode = SessionKey.mode(from: inputs.snapshot.sessionKey)
    let outcome: TurnOutcome
    do {
      outcome = try await agent.runTurn(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        buildResult: inputs.buildResult,
        sessionTainted: inputs.snapshot.isTainted,
        hasPinnedLessons: inputs.buildResult.hasPinnedLessons,
        sessionHasPrivateData: inputs.snapshot.hasPrivateData,
        todayTokens: inputs.todayTokens,
        todayUSD: inputs.todayUSD,
        origin: origin,
        proactiveTodayUSD: inputs.proactiveTodayUSD,
        carryOver: carryOver,
        mode: mode,
        threadId: SessionKey.threadId(from: inputs.snapshot.sessionKey)
      )
    } catch {
      failResume(runId: runId, stage: .turn, error: error)
      return
    }

    do {
      try await commit(
        outcome,
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        mode: mode,
        ownerNotices: inputs.buildResult.ownerNotices,
        origin: origin
      )
    } catch {
      logger.error("resume commit failed for run \(runId): \(error)")
    }
  }
}

/// Where a resume gave up. A failed assembly leaves the turn unfinished; a failed `runTurn` is the
/// provider round-trip itself.
enum ResumeStage: String {
  case contextBuild = "context build"
  case turn

  /// The run's terminal cause for a resume that gave up at this stage with this error.
  ///
  /// A `StoreError` wins over the stage: the resume path reads `resumeUsage` and the context
  /// snapshot from SQLite, so a full or unreadable disk surfaces here and is knowable. Recording a
  /// knowable storage failure as the stage's generic cause would file it under the wrong bucket for
  /// everything downstream that reads this column. The stage-only cause is deliberately not
  /// reachable on its own, so no caller can record less than what is known.
  func terminalCause(for error: any Error) -> TerminalCause {
    guard error is StoreError else {
      return stageCause
    }
    return .storageFailure
  }

  private var stageCause: TerminalCause {
    switch self {
    case .contextBuild: .incomplete
    case .turn: .providerFailure
    }
  }
}

// MARK: - Resume Failure Handling

private extension TurnRunner {
  /// The resumed run's origin, or nil when it cannot be read — a resume runs inside the waiter's
  /// `park`, so both "no such run" and a failed read resolve in-band by abandoning the resume.
  func resumeOrigin(runId: Int64) -> RunOrigin? {
    do {
      guard let origin = try runs.runOrigin(runId: runId) else {
        logger.debug("run \(runId) has no origin at resume; skipping")
        return nil
      }
      return origin
    } catch {
      logger.error("resume origin read failed for run \(runId): \(error)")
      return nil
    }
  }

  /// `resume`'s shared failure tail: every pre-commit failure fails the run in-band (best-effort)
  /// so the lane frees — `resume` is non-throwing by contract.
  func failResume(runId: Int64, stage: ResumeStage, error: any Error) {
    logger.error("resume \(stage.rawValue) failed for run \(runId): \(error)")
    try? runs.failRun(runId: runId, cause: stage.terminalCause(for: error), now: now())
  }
}
