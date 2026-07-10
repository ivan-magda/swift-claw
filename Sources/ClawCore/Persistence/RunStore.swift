import Foundation

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
  public let expiresTs: Date  // now + approval_expiry
  // NOTE: no `usage` field. The suspending round-trip's `provider_usage` row is already written
  // mid-loop by `AgentRuntime` before dispatch (crash-safe); re-inserting it here would double the
  // day budget AND the resume carry-over, since `provider_usage` has no dedup key and both
  // totals SUM every row. The commit persists the checkpoint only, never usage.

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

public protocol RunStore: Sendable {
  /// PENDING → RUNNING through `RunFSM`, returning the run's origin in the same write; nil means
  /// the run is absent or no longer pending (one query, no separate origin read). `policyVersion`
  /// is stamped onto `runs.policy_version` in the SAME UPDATE as the flip; nil records no
  /// fingerprint.
  func pickUp(runId: Int64, policyVersion: String?, now: Date) throws -> RunOrigin?
  /// Atomicity: assistant message + run→DONE + provider_usage + outbox chunk(s) in ONE txn,
  /// committed before any send. If cancellation/supersede already won, records usage only.
  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws -> RunCommitResult
  /// Failure/degradation commit: executed exchange rows + provider_usage + run→FAILED +
  /// degradation outbox in ONE txn. If cancellation/supersede already won, records usage when
  /// present but writes no reply and no exchanges.
  func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws -> RunCommitResult
  /// RUNNING → FAILED through `RunFSM`; no-ops unless the run is RUNNING.
  func failRun(runId: Int64, now: Date) throws
  /// Terminates the current RUNNING turn for `/stop`; returns the affected run, if any.
  func cancelActiveRun(sessionId: Int64, reason: CancelReason, now: Date) throws
    -> Int64?
  /// Terminates RUNNING and queued PENDING turns for `/new`.
  func supersedeSessionRuns(sessionId: Int64, now: Date) throws -> [Int64]
  /// Boot sweep: every PENDING/RUNNING orphan → FAILED (+ jobFailed for job runs), one
  /// degradation notice per run that never delivered. `heartbeatNoticeChatId` is the
  /// config-resolved owner DM for crashed heartbeat runs — their synthetic
  /// session key carries no chat id; nil (heartbeat unconfigured) skips the notice only.
  func reconcileRunsAtBoot(
    now: Date,
    degradationText: String,
    heartbeatNoticeChatId: Int64?
  ) throws -> [DegradationReply]
  /// Snapshot of run-table health: in-flight count, age of oldest running run, last
  /// success/failure timestamps, and count of consecutive failures at the head of the table.
  func runsHealth(now: Date) throws -> RunsHealth
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
  ) throws -> SuspendedCommitReceipt
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
  ) throws -> ApprovedExecutionClaim
  /// Approve resume, post-execution half: UPDATE the claimed placeholder observation in place
  /// with the tool's real result. Only ever called after `claimApprovedExecution` returned
  /// `.committed` for the same ids.
  func fillClaimedObservation(runId: Int64, observationMessageId: Int64, content: String)
    throws
  /// memory_write fused path (exactly-once): the memory item insert (via
  /// `MemoryStoreGRDB.insertItem`) and the observation UPDATE share ONE txn, gated by the SAME
  /// placeholder + AWAITING_APPROVAL → RUNNING guards as `claimApprovedExecution` — the side
  /// effect is in-DB, so claim and effect fuse instead of splitting.
  func applyApprovedMemoryWrite(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    observationMessageId: Int64,
    item: NewMemoryItem,
    observationContent: String,
    notResumableObservationContent: String,
    now: Date
  ) throws -> ApprovedExecutionClaim
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
  ) throws -> ClaimedApprovalBootOutcome
  /// Budget carry-over inputs: rounds = COUNT(role='assistant'),
  /// toolCalls = COUNT(role='tool') for the run; tokens/costUSD summed over `provider_usage`.
  func resumeUsage(runId: Int64) throws -> ResumeUsage
  /// The run's origin, read WITHOUT a re-pick-up (the resume path never re-flips PENDING).
  func runOrigin(runId: Int64) throws -> RunOrigin?
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
  ) throws -> Bool
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
  ) throws -> RunCommitResult
}

public extension RunStore {
  /// The no-stamp pick-up (the resume path, which never re-stamps, and every non-interactive
  /// caller): PENDING → RUNNING without touching `runs.policy_version`.
  func pickUp(runId: Int64, now: Date) throws -> RunOrigin? {
    try pickUp(runId: runId, policyVersion: nil, now: now)
  }
}
