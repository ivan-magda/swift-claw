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
  /// Optional result feedback address. The run-store validates and inserts it with final delivery.
  public let feedbackTarget: NewFeedbackTarget?

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
    providerState: ProviderExchangeState? = nil,
    feedbackTarget: NewFeedbackTarget? = nil
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
    self.feedbackTarget = feedbackTarget
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

/// One already-executed observation of the suspending batch, in the order it ran.
public struct ToolObservationRow: Sendable, Equatable {
  public let toolCallId: String
  public let content: String

  public init(toolCallId: String, content: String) {
    self.toolCallId = toolCallId
    self.content = content
  }
}

/// Everything the suspend commit persists in ONE transaction. Mirrors `AssistantTurn`, plus
/// the pending action the approval binds to and the button-carrying outbox chunk(s). `promptChunks`
/// carry `replyMarkup` already; the store stamps `approvalId` on the button chunk after inserting
/// the `approvals` row (the id is unknown until then).
public struct SuspendedTurnCommit: Sendable {
  public let assistantContent: String
  public let toolCallsJSON: String
  public let completedObservations: [ToolObservationRow]

  public let pending: PendingToolAction

  public let ownerUserId: Int64  // the run's delivery chat id
  public let nonce: String  // caller-generated via ApprovalNonce.generate()

  public let promptChunks: [OutboxChunk]

  public let setTainted: Bool
  public let setPrivateData: Bool

  /// The parked anchor's replay state, committed in the same transaction as the checkpoint so a
  /// resume replays the round the run actually took rather than a stateless reconstruction of it.
  public let providerState: ProviderExchangeState?

  public let expiresTs: Date  // now + approval_expiry
  // NOTE: no `usage` field. The suspending round-trip's `provider_usage` row is already written
  // mid-loop by `AgentRuntime` before dispatch (crash-safe), so the commit has nothing left to
  // persist: it carries the checkpoint only, never usage.

  public init(
    assistantContent: String,
    toolCallsJSON: String,
    completedObservations: [ToolObservationRow],
    pending: PendingToolAction,
    ownerUserId: Int64,
    nonce: String,
    promptChunks: [OutboxChunk],
    setTainted: Bool,
    setPrivateData: Bool,
    providerState: ProviderExchangeState? = nil,
    expiresTs: Date
  ) {
    self.assistantContent = assistantContent
    self.toolCallsJSON = toolCallsJSON
    self.completedObservations = completedObservations

    self.pending = pending

    self.ownerUserId = ownerUserId
    self.nonce = nonce

    self.promptChunks = promptChunks

    self.setTainted = setTainted
    self.setPrivateData = setPrivateData

    self.providerState = providerState

    self.expiresTs = expiresTs
  }
}

/// The suspend commit's outputs the waiter and boot re-park need: the new approval id and the
/// placeholder observation row's message id (the continuation bound).
public struct SuspendedCommitReceipt: Sendable, Equatable {
  public let approvalId: Int64
  public let observationMessageId: Int64

  public init(approvalId: Int64, observationMessageId: Int64) {
    self.approvalId = approvalId
    self.observationMessageId = observationMessageId
  }
}

/// The safe, owner-facing rendering of an approved action for the `.toolCall` audit row: the tool
/// name plus an already-redacted argument summary. The raw canonical arguments are never audited.
public struct ApprovedExecutionAudit: Sendable, Equatable {
  public let tool: String
  public let argsRedacted: String

  public init(tool: String, argsRedacted: String) {
    self.tool = tool
    self.argsRedacted = argsRedacted
  }
}

/// Everything the post-execution resume persists for a claimed observation in ONE transaction: the
/// observation `content` and its `status`, the state-guarded session provenance flags, and the
/// `.toolCall` audit rendered from `audit`. `setTainted`/`setPrivateData` are applied only for a
/// current or `/stop`-cancelled run; a superseded run keeps its flags off so the fresh window stays
/// clean while its old transcript and audit still record what ran.
public struct ClaimedObservationFill: Sendable, Equatable {
  public let content: String
  public let status: ToolObservationStatus

  public let setTainted: Bool
  public let setPrivateData: Bool

  public let audit: ApprovedExecutionAudit

  public let now: Date

  public init(
    content: String,
    status: ToolObservationStatus,
    setTainted: Bool,
    setPrivateData: Bool,
    audit: ApprovedExecutionAudit,
    now: Date
  ) {
    self.content = content
    self.status = status

    self.setTainted = setTainted
    self.setPrivateData = setPrivateData

    self.audit = audit

    self.now = now
  }
}

public protocol RunStore: Sendable {
  /// PENDING → RUNNING through `RunFSM`, returning the run's origin in the same write; nil means
  /// the run is absent or no longer pending (one query, no separate origin read). `policyVersion`
  /// is stamped onto `runs.policy_version` in the SAME UPDATE as the flip; nil records no
  /// fingerprint.
  func pickUp(
    runId: Int64,
    policyVersion: String?,
    now: Date
  ) throws(StoreError) -> RunOrigin?
  /// Atomicity: assistant message + run→DONE + provider_usage + outbox chunk(s) in ONE txn,
  /// committed before any send. If cancellation/supersede already won, records usage only.
  func commitAssistantTurn(
    _ turn: AssistantTurn,
    now: Date
  ) throws(StoreError) -> RunCommitResult
  /// Failure/degradation commit: executed exchange rows + provider_usage + run→FAILED +
  /// degradation outbox in ONE txn. If cancellation/supersede already won, records usage when
  /// present but writes no reply and no exchanges.
  func commitDegradedTurn(
    _ turn: DegradedTurn,
    now: Date
  ) throws(StoreError) -> RunCommitResult
  /// RUNNING → FAILED through `RunFSM`; no-ops unless the run is RUNNING. `cause` is the caller's
  /// own reason for failing the run — the terminal receipt records it verbatim.
  func failRun(runId: Int64, cause: TerminalCause, now: Date) throws(StoreError)
  /// Terminates the current RUNNING turn for `/stop`; returns the affected run, if any.
  func cancelActiveRun(
    sessionId: Int64,
    reason: CancelReason,
    now: Date
  ) throws(StoreError) -> Int64?
  /// Terminates RUNNING and queued PENDING turns for `/new`.
  func supersedeSessionRuns(
    sessionId: Int64,
    now: Date
  ) throws(StoreError) -> [Int64]
  /// Boot sweep: every PENDING/RUNNING orphan → FAILED (+ jobFailed for job runs), one
  /// degradation notice per run that never delivered. `heartbeatNoticeChatId` is the
  /// config-resolved owner DM for crashed heartbeat runs — their synthetic
  /// session key carries no chat id; nil (heartbeat unconfigured) skips the notice only.
  func reconcileRunsAtBoot(
    now: Date,
    degradationText: String,
    heartbeatNoticeChatId: Int64?
  ) throws(StoreError) -> [DegradationReply]
  /// Snapshot of run-table health: in-flight count, age of oldest running run, last
  /// success/failure timestamps, and count of consecutive failures at the head of the table.
  func runsHealth(now: Date) throws(StoreError) -> RunsHealth
  /// Suspend checkpoint — ONE txn (mirrors `commitAssistantTurn`): the anchor assistant row
  /// (content + tool_calls JSON), every completed observation, a real PLACEHOLDER observation row
  /// (role tool, the pending toolCallId, content "awaiting owner approval") to pin rowid adjacency,
  /// the `approvals` row (policy_version copied from the run row in-txn), `RUNNING→AWAITING_APPROVAL`,
  /// `setTainted`/`setPrivateData`, the `approvalRequested` audit, and the approval-prompt outbox
  /// chunk(s). Commit, then send.
  func commitSuspendedTurn(
    runId: Int64,
    sessionId: Int64,
    commit: SuspendedTurnCommit,
    now: Date
  ) throws(StoreError) -> SuspendedCommitReceipt
  /// Approve resume, pre-execution half (file_write / web_fetch): one txn, guarded on the
  /// placeholder check (per-approval exactly-once) and the AWAITING_APPROVAL → RUNNING flip. The
  /// caller executes the recorded action ONLY on `.committed` — claiming BEFORE the external
  /// effect is what stops a write from landing after `/stop`//`new` drove the run terminal. On
  /// `.runNotResumable` the placeholder is resolved with `notResumableObservationContent` in the
  /// same txn so history never dangles.
  func claimApprovedExecution(
    runId: Int64,
    observationMessageId: Int64,
    notResumableObservationContent: String,
    now: Date
  ) throws(StoreError) -> ApprovedExecutionClaim
  /// Approve resume, post-execution half: UPDATE the claimed placeholder observation in place with
  /// the tool's real result, apply the state-guarded taint/private-data provenance, and append the
  /// `.toolCall` audit — all in ONE transaction, so a fault rolls back content, flags, and audit
  /// together. Only ever called after `claimApprovedExecution` returned `.committed` for the same
  /// ids.
  func fillClaimedObservation(
    runId: Int64,
    observationMessageId: Int64,
    fill: ClaimedObservationFill
  ) throws(StoreError)
  /// memory_write fused path (exactly-once): the memory item insert (via
  /// `MemoryStoreGRDB.insertItem`), the observation UPDATE, and the `.toolCall` audit share ONE
  /// txn, gated by the SAME placeholder + AWAITING_APPROVAL → RUNNING guards as
  /// `claimApprovedExecution` — the side effect is in-DB, so claim and effect fuse instead of
  /// splitting.
  func applyApprovedMemoryWrite(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    observationMessageId: Int64,
    item: NewMemoryItem,
    observationContent: String,
    audit: ApprovedExecutionAudit,
    notResumableObservationContent: String,
    now: Date
  ) throws(StoreError) -> ApprovedExecutionClaim
  /// Boot settlement of the claimed crash window: an APPROVED approval whose observation
  /// is still the placeholder but whose run left AWAITING_APPROVAL means the pre-execution claim
  /// committed and the process died before the result record — whether the external effect landed
  /// is unknowable, so no replay. One txn: fail the run if it is not already terminal, resolve the
  /// placeholder with `observationContent`, and enqueue `noticeText` for the owner UNCONDITIONALLY
  /// (the generic boot degradation notice is suppressed for runs that already delivered their
  /// approval prompt, so this is the owner's only signal).
  func settleClaimedApprovalAtBoot(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    observationMessageId: Int64,
    observationContent: String,
    noticeChatId: Int64,
    noticeText: String,
    now: Date
  ) throws(StoreError) -> ClaimedApprovalBootOutcome
  /// Budget carry-over inputs: rounds = COUNT(role='assistant'),
  /// toolCalls = COUNT(role='tool') for the run; tokens/costUSD summed over `provider_usage`.
  func resumeUsage(runId: Int64) throws(StoreError) -> ResumeUsage
  /// The run's origin, read WITHOUT a re-pick-up (the resume path never re-flips PENDING).
  func runOrigin(runId: Int64) throws(StoreError) -> RunOrigin?
  /// The scheduled job this run fired for, as the fire that created it wrote it and nothing since
  /// has changed it. Nil for every run with no job — inbound turns and heartbeats. The pinned
  /// lesson read compares it against the job its learning binding claims: a lesson set is named by
  /// the pair `(job_id, digest)`, so a digest that resolves is not yet proof of the right owner.
  func jobId(runId: Int64) throws(StoreError) -> Int64?
  /// Stale-policy crash-window belt: fail the run (AWAITING_APPROVAL → FAILED), resolve the
  /// placeholder observation with `observationContent` (left dangling it would assert a pending
  /// approval to every later assembly and false-trigger the boot claimed-window settlement), and
  /// append the `approvalDenied`/`stale_policy` audit — ONE txn, while the approval row stays
  /// APPROVED (the one documented granted-then-denied pair). Returns false when the run was not
  /// AWAITING.
  func failRunStalePolicy(
    runId: Int64,
    sessionId: Int64,
    observationMessageId: Int64,
    observationContent: String,
    now: Date
  ) throws(StoreError) -> Bool
  /// Deny/cancel resolution: fill the placeholder observation row in place with the synthetic
  /// denial `content` so persisted history never holds a dangling tool_call, then drive the run to
  /// its terminal state. `cancel == nil` is the owner-deny / expiry path
  /// (AWAITING_APPROVAL → FAILED via `resolveDenied`, returns `.committed`); `cancel != nil` is the
  /// `/stop`//`new` path whose command transaction already flipped the run to CANCELLED/SUPERSEDED,
  /// so the FSM no-ops the transition and the method returns `.ignored` after fixing the
  /// observation. One transaction.
  func resolveDeniedObservation(
    runId: Int64,
    observationMessageId: Int64,
    content: String,
    cancel: CancelReason?,
    now: Date
  ) throws(StoreError) -> RunCommitResult
}

public extension RunStore {
  /// The no-stamp pick-up (the resume path, which never re-stamps, and every non-interactive
  /// caller): PENDING → RUNNING without touching `runs.policy_version`.
  func pickUp(runId: Int64, now: Date) throws(StoreError) -> RunOrigin? {
    try pickUp(runId: runId, policyVersion: nil, now: now)
  }
}
