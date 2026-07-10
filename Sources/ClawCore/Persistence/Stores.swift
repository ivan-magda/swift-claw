import Foundation

public protocol AllowlistStore: Sendable {
  func seedAllowlist(userIds: [Int64]) throws
  func allowlistContains(userId: Int64) throws -> Bool
  func allowlistCount() throws -> Int
}

public protocol ProcessedUpdateStore: Sendable {
  /// INSERT OR IGNORE → true if newly claimed, false if already seen.
  /// Synchronous: no await may span the check, so the dedup claim can't interleave.
  func claimUpdate(updateId: Int64) throws -> Bool
}

public enum CommandClaim: Sendable, Equatable {
  case duplicate
  case claimed(sessionId: Int64)
}

public struct StopCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionId: Int64?
  /// Every run `/stop` terminated — the RUNNING turn AND any queued PENDING turns (spec FSM:
  /// PENDING + /stop → CANCELLED). Empty when there was nothing to stop.
  public let cancelledRunIds: [Int64]
  /// PENDING approvals of the terminated runs, CAS'd to REJECTED (decision `cancelled`) in the same
  /// command transaction (§6.4). The handler signals the coordinator per id so a held/boot-parked
  /// lane releases. Defaulted so the `newlyClaimed: false` early return needs no change.
  public let resolvedApprovalIds: [Int64]

  public init(
    newlyClaimed: Bool,
    sessionId: Int64?,
    cancelledRunIds: [Int64],
    resolvedApprovalIds: [Int64] = []
  ) {
    self.newlyClaimed = newlyClaimed
    self.sessionId = sessionId
    self.cancelledRunIds = cancelledRunIds
    self.resolvedApprovalIds = resolvedApprovalIds
  }
}

public struct NewCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionId: Int64?
  public let supersededRunIds: [Int64]
  /// PENDING approvals of the superseded runs, CAS'd to REJECTED (decision `superseded`) in the
  /// same command transaction (§6.4). The handler signals the coordinator per id. Defaulted so the
  /// `newlyClaimed: false` early return needs no change.
  public let resolvedApprovalIds: [Int64]

  public init(
    newlyClaimed: Bool,
    sessionId: Int64?,
    supersededRunIds: [Int64],
    resolvedApprovalIds: [Int64] = []
  ) {
    self.newlyClaimed = newlyClaimed
    self.sessionId = sessionId
    self.supersededRunIds = supersededRunIds
    self.resolvedApprovalIds = resolvedApprovalIds
  }
}

public protocol CommandStore: Sendable {
  /// Atomic `/stop`: claim update + resolve session + every PENDING/RUNNING→CANCELLED + one
  /// audit row per cancelled run, in one write.
  func applyStop(updateId: Int64, sessionKey: String, now: Date) throws -> StopCommandResult
  /// Atomic `/new`: claim update + resolve session + RUNNING/PENDING→SUPERSEDED +
  /// resetWindowAndDetaint + audit in one write.
  func applyNew(updateId: Int64, sessionKey: String, now: Date) throws -> NewCommandResult
}

public struct MemoryCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let item: MemoryItem?

  public init(newlyClaimed: Bool, item: MemoryItem?) {
    self.newlyClaimed = newlyClaimed
    self.item = item
  }
}

public protocol MemoryStore: Sendable {
  func append(_ newItem: NewMemoryItem, now: Date) throws -> MemoryItem
  func list(kind: MemoryKind?, limit: Int) throws -> [MemoryItem]
  func get(id: Int64) throws -> MemoryItem?
  func delete(id: Int64) throws -> Bool
  func fetchRanked(excludeSensitive: Bool, limit: Int) throws -> [MemoryItem]
}

public protocol MemoryCommandStore: Sendable {
  /// Atomic confirmed remember: claim update + insert memory item + audit in one write.
  func applyRemember(
    updateId: Int64,
    item: NewMemoryItem,
    now: Date
  ) throws -> MemoryCommandResult
  /// Atomic confirmed delete: claim update + hard-delete memory item + audit in one write.
  func applyForget(updateId: Int64, itemId: Int64, now: Date) throws -> MemoryCommandResult
}

public struct ScheduleArmResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let job: ScheduledJob?

  public init(newlyClaimed: Bool, job: ScheduledJob?) {
    self.newlyClaimed = newlyClaimed
    self.job = job
  }
}

public protocol ScheduleCommandStore: Sendable {
  /// Atomic confirmed arm (spec §8): claim update + insert job + jobCreated audit in one write.
  /// The inserted job is the exact parked draft — the caller never re-parses (TOCTOU kill).
  func applyArm(updateId: Int64, job: NewScheduledJob, now: Date) throws -> ScheduleArmResult
}

public protocol Retriever: Sendable {
  func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws -> [RecallHit]
}

public protocol UpdateCursorStore: Sendable {
  func loadCursor() throws -> Int64?
  func advanceCursor(to updateId: Int64) throws
}

public protocol SessionMessageStore: Sendable {
  func loadOrCreateSession(sessionKey: String, now: Date) throws -> Int64
  func claimCommandUpdate(updateId: Int64, sessionKey: String, now: Date) throws -> CommandClaim
  func findSession(sessionKey: String) throws -> Int64?
  /// Fused transaction: claim the update, upsert the session, insert the user message, create the
  /// PENDING run, and stamp its trigger message in one write. Duplicates create nothing.
  func claimAndPersistInbound(_ inbound: InboundMessage) throws -> ClaimResult
  /// Context returned oldest-first and bounded to the message this run is answering.
  func loadContext(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws -> [StoredMessage]
  /// Context snapshot returned oldest-first and bounded to the message this run is answering.
  /// Includes the durable session metadata the assembler needs for recall dedup and taint reads.
  func loadContextSnapshot(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws -> SessionContextSnapshot
  /// Advances the `/new` context boundary to the latest message and clears session taint.
  func resetWindowAndDetaint(sessionId: Int64, now: Date) throws
}

/// One already-executed observation of the suspending batch, in the order it ran (spec §5.3).
public struct ToolObservationRow: Sendable, Equatable {
  public let toolCallId: String
  public let content: String

  public init(toolCallId: String, content: String) {
    self.toolCallId = toolCallId
    self.content = content
  }
}

/// Everything the §5.3 suspend commit persists in ONE transaction. Mirrors `AssistantTurn`, plus
/// the pending action the approval binds to and the button-carrying outbox chunk(s). `promptChunks`
/// carry `replyMarkup` already; the store stamps `approvalId` on the button chunk after inserting
/// the `approvals` row (the id is unknown until then).
public struct SuspendedTurnCommit: Sendable {
  public let assistantContent: String
  public let toolCallsJSON: String
  public let completedObservations: [ToolObservationRow]
  public let pending: PendingToolAction
  public let ownerUserId: Int64  // the run's delivery chat id (§4.4)
  public let nonce: String  // caller-generated via ApprovalNonce.generate()
  public let promptChunks: [OutboxChunk]
  public let setTainted: Bool
  public let setPrivateData: Bool
  public let expiresTs: Date  // now + approval_expiry
  // NOTE: no `usage` field. The suspending round-trip's `provider_usage` row is already written
  // mid-loop by `AgentRuntime` before dispatch (crash-safe); re-inserting it here would double the
  // day budget AND the §6.3 resume carry-over, since `provider_usage` has no dedup key and both
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
/// placeholder observation row's message id (§6.3 continuation bound).
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
  /// the run is absent or no longer pending — the guard semantics are unchanged (spec §10,
  /// preamble deviation 3: one query, no separate origin read). `policyVersion` (spec §3.2) is
  /// stamped onto `runs.policy_version` in the SAME UPDATE as the flip; nil records no fingerprint.
  func pickUp(runId: Int64, policyVersion: String?, now: Date) throws -> RunOrigin?
  /// F6 atomicity: assistant message + run→DONE + provider_usage + outbox chunk(s) in ONE txn,
  /// committed before any send. If cancellation/supersede already won, records usage only.
  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws -> RunCommitResult
  /// Failure/degradation commit: executed exchange rows (§11) + provider_usage + run→FAILED +
  /// degradation outbox in ONE txn. If cancellation/supersede already won, records usage when
  /// present but writes no reply and no exchanges.
  func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws -> RunCommitResult
  /// RUNNING → FAILED through `RunFSM`; no-ops unless the run is RUNNING.
  func failRun(runId: Int64, now: Date) throws
  /// Terminates the current RUNNING turn for `/stop`; returns the affected run, if any.
  func cancelActiveRun(sessionId: Int64, reason: CancelReason, now: Date) throws -> Int64?
  /// Terminates RUNNING and queued PENDING turns for `/new`.
  func supersedeSessionRuns(sessionId: Int64, now: Date) throws -> [Int64]
  /// Boot sweep: every PENDING/RUNNING orphan → FAILED (+ jobFailed for job runs), one
  /// degradation notice per run that never delivered. `heartbeatNoticeChatId` is the
  /// config-resolved owner DM for crashed heartbeat runs (spec §12/A6) — their synthetic
  /// session key carries no chat id; nil (heartbeat unconfigured) skips the notice only.
  func reconcileRunsAtBoot(
    now: Date,
    degradationText: String,
    heartbeatNoticeChatId: Int64?
  ) throws -> [DegradationReply]
  /// Snapshot of run-table health: in-flight count, age of oldest running run, last
  /// success/failure timestamps, and count of consecutive failures at the head of the table.
  func runsHealth(now: Date) throws -> RunsHealth
  /// §5.3 suspend checkpoint — ONE txn (mirrors `commitAssistantTurn`): the anchor assistant row
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
  func fillClaimedObservation(runId: Int64, observationMessageId: Int64, content: String) throws
  /// Task 16 memory_write fused path (§6.3 exactly-once): the memory item insert (via
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
  /// Boot settlement of the claimed crash window (§6.6): an APPROVED approval whose observation
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
  /// Task 16 §6.3 budget carry-over inputs (D4): rounds = COUNT(role='assistant'),
  /// toolCalls = COUNT(role='tool') for the run; tokens/costUSD summed over `provider_usage`.
  func resumeUsage(runId: Int64) throws -> ResumeUsage
  /// Task 16: the run's origin, read WITHOUT a re-pick-up (the resume path never re-flips PENDING).
  func runOrigin(runId: Int64) throws -> RunOrigin?
  /// Task 16 §6.5 crash-window belt: fail the run (AWAITING_APPROVAL → FAILED) and append the
  /// `approvalDenied`/`stale_policy` audit in ONE txn, while the approval row stays APPROVED — the
  /// one documented granted-then-denied pair. Returns false when the run was not AWAITING.
  func failRunStalePolicy(runId: Int64, sessionId: Int64, now: Date) throws -> Bool
  /// §6.4 deny/cancel resolution: fill the placeholder observation row in place with the synthetic
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

/// The four outcomes of the §6.2 step-5 approve CAS. Only `.approved`/`.stalePolicy` mutate the
/// row (each with its own same-txn audit); `.notPending`/`.expiredRow` leave it untouched for the
/// caller to route (duplicate-tap toast, or the deny path for an aged-out row).
public enum ApprovalApproveOutcome: Sendable, Equatable {
  case approved(Approval)
  case stalePolicy(Approval)
  case notPending
  case expiredRow
}

public protocol ApprovalStore: Sendable {
  /// Lookup by nonce ONLY (the callback's single-use credential), never by id.
  func approval(nonce: String) throws -> Approval?
  func approval(id: Int64) throws -> Approval?
  /// §6.2 step 5, one transaction: still PENDING, unexpired, stored argsHash ==
  /// `ApprovalArgsHash.sha256Hex(canonicalArgsJSON)`, and storedPolicyVersion ==
  /// `currentPolicyVersion`. All satisfied → APPROVED + `approvalGranted`. Hash/version mismatch
  /// → REJECTED + decision `stale_policy` + `approvalDenied`, returns `.stalePolicy`.
  func approve(id: Int64, currentPolicyVersion: String, now: Date) throws -> ApprovalApproveOutcome
  /// CAS PENDING→(EXPIRED when decision is `.expired`, else REJECTED) + `approvalDenied` audit in
  /// the same txn. false when the row is no longer PENDING (a racing resolver won).
  func deny(id: Int64, decision: ApprovalDecision, now: Date) throws -> Bool
  /// Ticker/boot sweep: CAS every PENDING row with `expires_ts <= now` → EXPIRED (+ `approvalDenied`
  /// audit, decision `expired`) and return the swept rows for the waiter signals.
  func sweepExpired(now: Date) throws -> [Approval]
  /// Boot: PENDING rows (any expiry), plus resolved rows whose run is still AWAITING_APPROVAL —
  /// APPROVED (§6.5 grant crash window) and REJECTED/EXPIRED (the deny-side twin: the deny CAS +
  /// audit committed but the waiter's run-fail commit did not). Terminal-run rows never return.
  func unresolvedAtBoot() throws -> [Approval]
  /// Boot hygiene: a terminal run holding a PENDING approval → REJECTED + `approvalDenied`
  /// (decision `cancelled`). Returns the count cleaned.
  func resolveOrphans(now: Date) throws -> Int
  /// Doctor: outstanding PENDING count + the oldest pending row's age.
  func approvalsHealth(now: Date) throws -> ApprovalsHealth
}

public protocol UsageStore: Sendable {
  func recordUsage(_ usage: ProviderUsage) throws
  /// Running totals over `provider_usage` for the calendar-day-UTC window containing `now` (D4).
  func todayTokensAndCost(now: Date) throws -> (tokens: Int, costUSD: Double)
  /// The same UTC-day window as `todayTokensAndCost(now:)`, restricted to usage whose run's
  /// origin is IN `origins` (JOIN provider_usage.run_id → runs.id — D6: no denormalized origin
  /// on usage rows). One query, one day-boundary evaluation (spec §11).
  func todayTokensAndCost(origins: [RunOrigin], now: Date) throws -> (tokens: Int, costUSD: Double)
  /// Count of `provider_usage` rows per `CostSource` in the calendar-day-UTC window (for doctor).
  func costSourceMix(now: Date) throws -> [CostSource: Int]
}

public protocol OutboxStore: Sendable {
  func claimOutbound(runId: Int64, chunk: OutboxChunk) throws -> Bool
  /// Claims a reply only while the owning run is still active (RUNNING or AWAITING_APPROVAL —
  /// a suspended run's own approval prompt must be deliverable, preamble D7).
  func claimOutboundIfRunActive(runId: Int64, chunk: OutboxChunk) throws -> Bool
  func markSent(runId: Int64, stepIndex: Int, telegramMessageId: Int64, now: Date) throws
  func pendingOutbound() throws -> [OutboxRow]
}

public protocol AuditLog: Sendable {
  func appendAudit(_ event: AuditEvent) throws
}

public struct ClaimedFire: Sendable, Equatable {
  public let runId: Int64
  public let sessionId: Int64
  public let triggerMessageId: Int64
  public let ownerChatId: Int64

  public init(runId: Int64, sessionId: Int64, triggerMessageId: Int64, ownerChatId: Int64) {
    self.runId = runId
    self.sessionId = sessionId
    self.triggerMessageId = triggerMessageId
    self.ownerChatId = ownerChatId
  }
}

public protocol ScheduledJobStore: Sendable {
  func create(_ job: NewScheduledJob, now: Date) throws -> ScheduledJob
  func job(id: Int64) throws -> ScheduledJob?
  func listAll() throws -> [ScheduledJob]
  func dueJobs(now: Date) throws -> [ScheduledJob]  // status='ACTIVE' AND next_occurrence <= now

  /// Spec §5.2 — the whole fused transaction. `due` is the CAS predicate (the stored
  /// next_occurrence being claimed); `fireAt` is T_fire (== due on time, the latest missed
  /// occurrence when coalescing); `nextOccurrence` nil ⇒ one-shot → COMPLETED. Creates the
  /// job session on first fire (session_key = SessionKey.scheduledJob(id:)), inserts the
  /// trigger message (role user, provenance trusted, text = job prompt), the PENDING run
  /// (origin 'scheduled', job_id set), and the jobExecuted audit row — one writeMapping.
  /// Returns nil when the CAS matches no row (claimed elsewhere / job mutated): no fire.
  func claimAndFire(
    jobId: Int64,
    due: Date,
    fireAt: Date,
    nextOccurrence: Date?,
    now: Date
  ) throws -> ClaimedFire?

  /// Spec §5.4 run-now: the same fused insert set with NO schedule advance. Requires
  /// status ACTIVE or PAUSED (nil otherwise). fireAt = now; jobExecuted audited in-txn.
  func fireNow(jobId: Int64, now: Date) throws -> ClaimedFire?

  /// Spec §5.3 skip: advance next_occurrence past now with no run (nil ⇒ one-shot →
  /// COMPLETED), update scheduler_state.last_misfire_at / last_misfire_skipped_count, and
  /// audit jobMisfire — one transaction. Returns false when the job was concurrently mutated.
  func skipMisfire(
    jobId: Int64,
    due: Date,
    nextOccurrence: Date?,
    skippedCount: Int,
    now: Date
  ) throws -> Bool

  /// ACTIVE→PAUSED, idempotent.
  func pause(id: Int64, now: Date) throws -> ScheduledJob?
  /// PAUSED→ACTIVE; the caller recomputes next_occurrence from now.
  func resume(id: Int64, nextOccurrence: Date?, now: Date) throws -> ScheduledJob?
  /// ACTIVE|PAUSED→CANCELLED, next NULL, row retained.
  func cancel(id: Int64, now: Date) throws -> ScheduledJob?

  func schedulerState() throws -> SchedulerState
  /// Upserts scheduler_state.last_tick_at.
  func recordTick(at tickTime: Date) throws

  /// Spec §12 (Phase 4): creates/reuses the sched:heartbeat session, inserts the template
  /// trigger message + PENDING run (origin 'heartbeat', job_id NULL), and updates
  /// scheduler_state heartbeat fields (last_heartbeat_at, day-counter roll) — one transaction.
  func fireHeartbeat(
    prompt: String,
    ownerChatId: Int64,
    now: Date,
    day: String
  ) throws -> ClaimedFire
}
