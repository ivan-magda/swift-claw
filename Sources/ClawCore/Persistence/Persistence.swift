import Foundation

public enum RunState: String, Sendable, Equatable, CaseIterable {
  /// Persisted after the inbound message and run are created atomically, before lane execution.
  case pending = "PENDING"
  /// Persisted when the session lane successfully picks up the turn.
  case running = "RUNNING"
  /// Terminal success: the assistant reply and outbox rows committed atomically.
  case done = "DONE"
  /// Terminal failure: the turn could not complete and should not be picked up again.
  case failed = "FAILED"
  /// Terminal cancellation requested by `/stop`.
  case cancelled = "CANCELLED"
  /// Terminal cancellation requested by `/new`; queued turns are superseded too.
  case superseded = "SUPERSEDED"
  /// Suspended to a durable checkpoint: an `approvals` row is the one source of truth for
  /// "blocked on approval"; resolved by callback, ticker, boot, or command.
  case awaitingApproval = "AWAITING_APPROVAL"

  /// The non-terminal states: a run in any of these can still advance and pick up an
  /// advanced context window. The single definition of "live" — `terminateActiveRuns` and the
  /// proactive-fire overlap guard both build their `state IN (…)` predicate from this set so the
  /// live triple is never duplicated. `pending` is included because a claimed-but-not-yet-picked-up
  /// run loads the current window at pickup.
  public static let liveStates: [RunState] = [.pending, .running, .awaitingApproval]

  /// The absorbing states: `RunFSM` returns nil for every event once a run reaches one, which is
  /// what makes a terminal transition win exactly once and lets its receipt be written there.
  public var isTerminal: Bool {
    !Self.liveStates.contains(self)
  }

  /// The complement of `liveStates`, derived rather than listed so a new state joins exactly one
  /// of the two sets.
  public static let terminalStates: [RunState] = allCases.filter(\.isTerminal)
}

/// The two command-owned reasons for terminating a live run.
///
/// This is intentionally narrower than `RunState`: callers cannot accidentally request an
/// unrelated terminal state such as `.done` or `.failed`.
public enum CancelReason: Sendable, Equatable {
  case cancelled
  case superseded
}

/// Outcome of a commit attempt at the run-store seam.
public enum RunCommitResult: Sendable, Equatable {
  /// The run was still RUNNING and the terminal state plus owner-visible side effects committed.
  case committed
  /// Cancellation/supersede had already won; provider usage was still durably recorded.
  case usageRecordedAfterTerminal
  /// The run was not in a state where this commit owns any side effect.
  case ignored
}

/// Outcome of the pre-execution claim at the approved-resume seam. The claim is what
/// makes an approved external write and a `/stop`//`new` cancellation mutually exclusive: both
/// contend on the run row's FSM transition, so exactly one side ever owns the effect.
public enum ApprovedExecutionClaim: Sendable, Equatable {
  /// The AWAITING_APPROVAL → RUNNING flip committed; the caller now owns the execution.
  case committed
  /// The observation is no longer the placeholder — a duplicate signal is replaying an
  /// already-executed resume. Nothing to do.
  case alreadyResumed
  /// The run reached a terminal state (`/stop`, `/new`) before the claim. Nothing may execute;
  /// the placeholder observation was resolved with the not-run note in the claim's transaction.
  case runNotResumable
}

/// Boot triage of an APPROVED approval whose observation is still the placeholder.
public enum ClaimedApprovalBootOutcome: Sendable, Equatable {
  /// The run is still AWAITING_APPROVAL: the crash landed between the approve CAS and the
  /// execution claim, nothing ran — the boot belt re-parks a waiter to replay the recorded action.
  case reparkForReplay
  /// The claim committed but the result record never landed (crash mid-execution): the run is
  /// terminal (or was failed here), the placeholder was resolved with the unknown-outcome note,
  /// and the owner notice was enqueued — all in one transaction.
  case settled
  /// The observation already holds a real result; nothing to do.
  case alreadyResolved
}

public enum Provenance: String, Sendable, Equatable {
  case trusted
  case untrusted
}

public enum MessageRole: String, Sendable, Equatable {
  case system
  case user
  case assistant
  case tool
}

public enum CostSource: String, Sendable, Equatable {
  case providerReturned = "provider_returned"
  case priceFile = "price_file"
  case heuristic
  /// A subscription route's confirmed zero. It is a distinct source rather than a $0
  /// `providerReturned` so an audit can tell "the plan covered this" from "the provider billed
  /// nothing", and so the never-a-silent-$0 rule is satisfied rather than bypassed.
  case includedPlan = "included_plan"
}

public enum SessionKey {
  private static let dmPrefix = "tg:dm:"
  private static let topicPrefix = "tg:topic:"
  private static let jobPrefix = "sched:job:"

  /// The forum's General topic carries no `message_thread_id`, so its key needs a suffix that no
  /// thread id can ever produce. A numeric coercion (0, or topic 1) would fuse two distinct
  /// conversations into one session.
  private static let generalTopicSuffix = "general"

  /// The heartbeat's dedicated persistent session. No chat id in the key —
  /// the delivery target is resolved from config, so `chatId(from:)` stays nil by design.
  public static let heartbeat = "sched:heartbeat"

  public static func telegramDM(chatId: Int64) -> String {
    "\(dmPrefix)\(chatId)"
  }

  /// One session per forum topic. `threadId` is nil in the General topic and in a non-forum group,
  /// which both collapse onto the chat's single General key — correct, since a non-forum group has
  /// exactly one conversation.
  public static func telegramTopic(chatId: Int64, threadId: Int64?) -> String {
    let suffix = threadId.map(String.init) ?? generalTopicSuffix
    return "\(topicPrefix)\(chatId):\(suffix)"
  }

  /// The one place a key is minted from an inbound message. Routing resolves the mode once and
  /// every handler funnels through here, so a topic can never be dropped on one path and honored
  /// on another.
  public static func telegram(for message: IncomingMessage, mode: ChatMode) -> String {
    switch mode {
    case .direct:
      telegramDM(chatId: message.chatId)
    case .group:
      telegramTopic(chatId: message.chatId, threadId: message.messageThreadId)
    }
  }

  /// A job's dedicated session, created lazily at first fire. No chat id in the key —
  /// the delivery target is `scheduled_jobs.owner_chat_id`, so `chatId(from:)` stays nil by design.
  public static func scheduledJob(id: Int64) -> String {
    "\(jobPrefix)\(id)"
  }

  public static func chatId(from key: String) -> Int64? {
    if key.hasPrefix(dmPrefix) {
      return Int64(key.dropFirst(dmPrefix.count))
    }
    guard let body = topicBody(of: key), let separator = body.lastIndex(of: ":") else {
      return nil
    }
    return Int64(body[body.startIndex..<separator])
  }

  /// The mode a session is being served in, recovered from its key alone — the derivation every
  /// consumer that holds only a session id (and therefore only its key) depends on. Scheduled-job
  /// and heartbeat sessions are the owner's own, so they read `.direct`.
  public static func mode(from key: String) -> ChatMode {
    key.hasPrefix(topicPrefix) ? .group : .direct
  }

  /// The forum topic to deliver into, or nil for the General topic and for every non-topic key.
  public static func threadId(from key: String) -> Int64? {
    guard let body = topicBody(of: key), let separator = body.lastIndex(of: ":") else {
      return nil
    }
    return Int64(body[body.index(after: separator)...])
  }

  private static func topicBody(of key: String) -> Substring? {
    key.hasPrefix(topicPrefix) ? key.dropFirst(topicPrefix.count) : nil
  }
}

public struct InboundMessage: Sendable, Equatable {
  public let updateId: Int64
  public let sessionKey: String
  public let chatId: Int64
  public let userId: Int64
  public let text: String
  public let isEdited: Bool
  public let provenance: Provenance
  /// Telegram's id for the message that triggered this turn, nil for an inbound with no Telegram
  /// origin (a scheduled job). It is the reply target an answer addresses, and the fused claim is
  /// the only write that touches the run row it belongs on.
  public let telegramMessageId: Int64?
  public let ts: Date

  public init(
    updateId: Int64,
    sessionKey: String,
    chatId: Int64,
    userId: Int64,
    text: String,
    isEdited: Bool,
    provenance: Provenance = .trusted,
    telegramMessageId: Int64? = nil,
    ts: Date
  ) {
    self.updateId = updateId
    self.sessionKey = sessionKey
    self.chatId = chatId
    self.userId = userId
    self.text = text
    self.isEdited = isEdited
    self.provenance = provenance
    self.telegramMessageId = telegramMessageId
    self.ts = ts
  }
}

public struct ClaimResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionId: Int64?
  public let messageId: Int64?
  public let runId: Int64?
  public let triggerMessageId: Int64?

  public init(
    newlyClaimed: Bool,
    sessionId: Int64?,
    messageId: Int64?,
    runId: Int64?,
    triggerMessageId: Int64?
  ) {
    self.newlyClaimed = newlyClaimed
    self.sessionId = sessionId
    self.messageId = messageId
    self.runId = runId
    self.triggerMessageId = triggerMessageId
  }
}

public struct StoredMessage: Sendable, Equatable {
  public let role: MessageRole
  public let content: String
  public let provenance: Provenance
  public let toolCallsJSON: String?
  public let toolCallId: String?
  public let providerState: ProviderExchangeState?
  public let image: ImagePart?

  public init(
    role: MessageRole,
    content: String,
    provenance: Provenance,
    toolCallsJSON: String? = nil,
    toolCallId: String? = nil,
    providerState: ProviderExchangeState? = nil,
    image: ImagePart? = nil
  ) {
    self.role = role
    self.content = content
    self.provenance = provenance
    self.toolCallsJSON = toolCallsJSON
    self.toolCallId = toolCallId
    self.providerState = providerState
    self.image = image
  }
}

public struct SessionContextSnapshot: Sendable, Equatable {
  /// The owning session's key, carried so a consumer holding only a `sessionId` can still derive
  /// the chat mode and the forum topic without a second read.
  public let sessionKey: String
  public let history: [StoredMessage]
  public let historyMessageIds: [Int64]
  public let windowStartMessageId: Int64?
  public let isTainted: Bool
  /// The persisted private-data flag, fed into the trifecta gate's private-data leg so the
  /// exfil gate stays armed even after the window rolls past the private read that set it.
  public let hasPrivateData: Bool

  public init(
    sessionKey: String,
    history: [StoredMessage],
    historyMessageIds: [Int64],
    windowStartMessageId: Int64?,
    isTainted: Bool,
    hasPrivateData: Bool
  ) {
    self.sessionKey = sessionKey
    self.history = history
    self.historyMessageIds = historyMessageIds
    self.windowStartMessageId = windowStartMessageId
    self.isTainted = isTainted
    self.hasPrivateData = hasPrivateData
  }
}

public struct ProviderUsage: Sendable, Equatable {
  /// The provider round-trip this row accounts for. Stored rows are unique on it, which is what
  /// makes a re-attempted commit write nothing instead of double-debiting the day: the second
  /// attempt presents the identity the first one already stored.
  public let providerCallID: ProviderCallID
  /// The owning run, or `nil` for spend issued outside any run (command-scoped LLM calls such as
  /// the /schedule parse). Plain day totals include nil-run rows; the origin-filtered totals
  /// cannot (the JOIN has nothing to match) — correct, since command spend is owner-interactive.
  public let runId: Int64?
  public let sessionId: Int64
  public let model: String
  public let promptTokens: Int
  public let completionTokens: Int
  public let costUSD: Double
  public let costSource: CostSource
  public let isEstimated: Bool
  public let ts: Date

  public init(
    providerCallID: ProviderCallID,
    runId: Int64?,
    sessionId: Int64,
    model: String,
    promptTokens: Int,
    completionTokens: Int,
    costUSD: Double,
    costSource: CostSource,
    isEstimated: Bool,
    ts: Date
  ) {
    self.providerCallID = providerCallID
    self.runId = runId
    self.sessionId = sessionId
    self.model = model
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.costUSD = costUSD
    self.costSource = costSource
    self.isEstimated = isEstimated
    self.ts = ts
  }

  /// Builds the row from its two independent provenances — resolved tokens and resolved cost. This
  /// is the single place the row's `isEstimated` is derived: a row is an estimate iff either input
  /// was guessed.
  public init(
    providerCallID: ProviderCallID,
    runId: Int64?,
    sessionId: Int64,
    model: String,
    usage: ResolvedUsage,
    cost: ResolvedCost,
    ts: Date
  ) {
    self.init(
      providerCallID: providerCallID,
      runId: runId,
      sessionId: sessionId,
      model: model,
      promptTokens: usage.usage.promptTokens,
      completionTokens: usage.usage.completionTokens,
      costUSD: cost.costUSD,
      costSource: cost.source,
      isEstimated: usage.isEstimated || cost.isEstimated,
      ts: ts
    )
  }
}

public struct OutboxChunk: Sendable, Equatable {
  public let stepIndex: Int
  public let chatId: Int64
  public let payload: String
  public let payloadHash: String
  public let approvalId: Int64?
  public let replyMarkup: String?

  public init(
    stepIndex: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String,
    approvalId: Int64? = nil,
    replyMarkup: String? = nil
  ) {
    self.stepIndex = stepIndex
    self.chatId = chatId
    self.payload = payload
    self.payloadHash = payloadHash
    self.approvalId = approvalId
    self.replyMarkup = replyMarkup
  }
}

/// Which producer enqueued an outbound row. A run's chunks carry its id; a learning notice belongs
/// to no run, so the source column is what tells the two apart in storage.
public enum DeliverySource: String, Sendable, Equatable, CaseIterable {
  case run
  case learning
}

/// One chunk of an owner-facing learning notice. It belongs to no run, so its delivery identity is
/// the subject it speaks about plus its position in that subject's message — which makes a resend
/// idempotent exactly as a run's chunks are.
public struct LearningNoticeChunk: Sendable, Equatable {
  /// The polymorphic digest of whatever the notice addresses — a candidate, an evaluation, a
  /// promotion — matching the `subject_digest` the feedback tables key on.
  public let subjectDigest: String
  public let ordinal: Int
  public let chatId: Int64
  public let payload: String
  public let payloadHash: String
  public let replyMarkup: String?

  public init(
    subjectDigest: String,
    ordinal: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String,
    replyMarkup: String? = nil
  ) {
    self.subjectDigest = subjectDigest
    self.ordinal = ordinal
    self.chatId = chatId
    self.payload = payload
    self.payloadHash = payloadHash
    self.replyMarkup = replyMarkup
  }
}

public struct OutboxRow: Sendable, Equatable {
  /// The row's identity, from the table's existing unique `dedup_key`. A learning notice has no
  /// run, so the run cannot be the identity; it stays as provenance.
  public let deliveryKey: String
  public let runId: Int64?
  public let stepIndex: Int
  public let chatId: Int64
  public let payload: String
  public let approvalId: Int64?
  public let replyMarkup: String?
  /// Stamped at enqueue from the run itself, so a row delivers into the topic that asked even
  /// after a restart, when no router is left to say where the answer belongs. Both nil in a DM.
  public let messageThreadId: Int64?
  public let replyToMessageId: Int64?

  /// Where this row goes, as the delivery seam takes it.
  public var target: DeliveryTarget {
    DeliveryTarget(
      chatId: chatId,
      messageThreadId: messageThreadId,
      replyToMessageId: replyToMessageId
    )
  }

  /// What a log line calls this row's origin: its run, or the learning source when it has none.
  public var originLabel: String {
    runId.map(String.init) ?? DeliverySource.learning.rawValue
  }

  public init(
    deliveryKey: String,
    runId: Int64?,
    stepIndex: Int,
    chatId: Int64,
    payload: String,
    approvalId: Int64? = nil,
    replyMarkup: String? = nil,
    messageThreadId: Int64? = nil,
    replyToMessageId: Int64? = nil
  ) {
    self.deliveryKey = deliveryKey
    self.runId = runId
    self.stepIndex = stepIndex
    self.chatId = chatId
    self.payload = payload
    self.approvalId = approvalId
    self.messageThreadId = messageThreadId
    self.replyToMessageId = replyToMessageId
    self.replyMarkup = replyMarkup
  }
}

public struct AssistantTurn: Sendable, Equatable {
  public let runId: Int64
  public let sessionId: Int64
  public let chatId: Int64
  public let content: String
  public let usage: ProviderUsage
  public let chunks: [OutboxChunk]
  public let exchanges: [ToolExchange]
  public let setTainted: Bool
  /// Sticky private-data flag — persisted like `setTainted`, on every commit path.
  public let setPrivateData: Bool
  /// The final assistant message's replay state, committed in the same transaction as the message
  /// it belongs to so an anchor and its state can never be persisted apart.
  public let providerState: ProviderExchangeState?

  public init(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    content: String,
    usage: ProviderUsage,
    chunks: [OutboxChunk],
    exchanges: [ToolExchange] = [],
    setTainted: Bool = false,
    setPrivateData: Bool = false,
    providerState: ProviderExchangeState? = nil
  ) {
    self.runId = runId
    self.sessionId = sessionId
    self.chatId = chatId
    self.content = content
    self.usage = usage
    self.chunks = chunks
    self.exchanges = exchanges
    self.setTainted = setTainted
    self.setPrivateData = setPrivateData
    self.providerState = providerState
  }
}

public struct DegradedTurn: Sendable, Equatable {
  public let runId: Int64
  public let sessionId: Int64
  public let chatId: Int64
  public let usage: ProviderUsage?
  public let chunk: OutboxChunk
  public let exchanges: [ToolExchange]
  public let setTainted: Bool
  /// Sticky private-data flag — persisted like `setTainted`, incl. on the failure path.
  public let setPrivateData: Bool
  /// Why this turn ended, supplied by the caller that knows. FAILED alone cannot tell a provider
  /// outage from a budget stop, a context failure or a policy block, and this commit writes the
  /// run's terminal receipt.
  public let cause: TerminalCause

  public init(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    usage: ProviderUsage?,
    chunk: OutboxChunk,
    exchanges: [ToolExchange] = [],
    setTainted: Bool = false,
    setPrivateData: Bool = false,
    cause: TerminalCause
  ) {
    self.runId = runId
    self.sessionId = sessionId
    self.chatId = chatId
    self.usage = usage
    self.chunk = chunk
    self.exchanges = exchanges
    self.setTainted = setTainted
    self.setPrivateData = setPrivateData
    self.cause = cause
  }
}

/// Who an audit event is attributed to. A small closed set so the audit trail can't record a
/// typo'd actor; persisted via `rawValue` at the store seam.
public enum AuditActor: String, Sendable, Equatable {
  case owner
  case groupMember = "group_member"
  case assistant
  case system
}

/// The category of an audit event (the specific tool/reason rides in `tool`/`decision`, not here).
/// Closed by design: a controlled vocabulary makes the audit log queryable and typo-proof. Add a
/// case when a new kind of event needs recording.
public enum AuditAction: String, Sendable, Equatable {
  case messageIn = "message_in"
  case toolCall = "tool_call"
  case memoryWrite = "memory_write"
  case memoryDelete = "memory_delete"
  case turnCompleted = "turn_completed"
  case turnDegraded = "turn_degraded"
  case turnBudgetStopped = "turn_budget_stopped"
  case budgetTripped = "budget_tripped"
  case turnCancelled = "turn_cancelled"
  case providerFallback = "provider_fallback"
  case turnSuperseded = "turn_superseded"
  case jobCreated = "job_created"
  case jobExecuted = "job_executed"
  case jobPaused = "job_paused"
  case jobResumed = "job_resumed"
  case jobCancelled = "job_cancelled"
  case jobFailed = "job_failed"
  case jobMisfire = "job_misfire"
  case jobOverlapSkipped = "job_overlap_skipped"
  case heartbeatFired = "heartbeat_fired"
  case heartbeatSuppressed = "heartbeat_suppressed"
  case heartbeatSkipped = "heartbeat_skipped"
  case approvalRequested = "approval_requested"
  case approvalGranted = "approval_granted"
  case approvalDenied = "approval_denied"
  case learningBound = "learning_bound"
}

public struct AuditEvent: Sendable, Equatable {
  public let actor: AuditActor
  public let action: AuditAction
  public let tool: String?
  public let argsRedacted: String
  public let resultSize: Int
  public let decision: String
  public let runId: Int64?
  public let sessionId: Int64?
  public let ts: Date

  public init(
    actor: AuditActor,
    action: AuditAction,
    tool: String? = nil,
    argsRedacted: String = "",
    resultSize: Int = 0,
    decision: String = "ok",
    runId: Int64? = nil,
    sessionId: Int64? = nil,
    ts: Date
  ) {
    self.actor = actor
    self.action = action
    self.tool = tool
    self.argsRedacted = argsRedacted
    self.resultSize = resultSize
    self.decision = decision
    self.runId = runId
    self.sessionId = sessionId
    self.ts = ts
  }
}

public struct RunsHealth: Sendable, Equatable {
  public let inFlight: Int
  public let oldestRunAgeSeconds: Double?
  public let lastFailedAt: Date?
  public let lastSuccessAt: Date?
  public let consecutiveFailures: Int

  public init(
    inFlight: Int,
    oldestRunAgeSeconds: Double?,
    lastFailedAt: Date?,
    lastSuccessAt: Date?,
    consecutiveFailures: Int
  ) {
    self.inFlight = inFlight
    self.oldestRunAgeSeconds = oldestRunAgeSeconds
    self.lastFailedAt = lastFailedAt
    self.lastSuccessAt = lastSuccessAt
    self.consecutiveFailures = consecutiveFailures
  }
}

/// Doctor snapshot of the approvals table: how many owner decisions are outstanding
/// and how long the oldest one has waited. `oldestPendingAgeSeconds` is nil when nothing is
/// pending. The ClawGateway renderer compares the age against `approval_expiry`.
public struct ApprovalsHealth: Sendable, Equatable {
  public let pendingCount: Int
  public let oldestPendingAgeSeconds: Int?

  public init(pendingCount: Int, oldestPendingAgeSeconds: Int?) {
    self.pendingCount = pendingCount
    self.oldestPendingAgeSeconds = oldestPendingAgeSeconds
  }
}

public struct DegradationReply: Sendable, Equatable {
  public let chatId: Int64
  public let runId: Int64
  public let text: String

  public init(chatId: Int64, runId: Int64, text: String) {
    self.chatId = chatId
    self.runId = runId
    self.text = text
  }
}
