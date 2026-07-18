import ClawCore
import Foundation
import GRDB

/// GRDB implementation of `ApprovalStore`. Mirrors `RunStoreGRDB`:
/// every write rides `database.writeMapping`, every state change funnels through the single
/// `transitionApproval` static (built like `RunStoreGRDB.transitionRun` but calling
/// `ApprovalFSM.reduce`), and every resolution appends its `approvalGranted`/`approvalDenied`
/// audit inside the same transaction. The `approvals` timestamp columns
/// are `.integer` UTC epoch seconds (v8 migration), so they travel through `EpochSecondCodec` —
/// never a raw `Date` bind, which GRDB would serialize as a string and break `expires_ts <= now`.
public struct ApprovalStoreGRDB: ApprovalStore {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func approval(nonce: String) throws(StoreError) -> Approval? {
    try database.readMapping { db in
      try Self.fetchApproval(db, whereClause: "nonce = ?", arguments: [nonce])
    }
  }

  public func approval(id: Int64) throws(StoreError) -> Approval? {
    try database.readMapping { db in
      try Self.fetchApproval(db, id: id)
    }
  }

  public func approve(
    id: Int64,
    currentPolicyVersion: String,
    now: Date
  ) throws(StoreError) -> ApprovalApproveOutcome {
    try database.writeMapping { db in
      guard let approval = try Self.fetchApproval(db, id: id), approval.state == .pending else {
        return .notPending
      }
      guard approval.expiresTs > now else {
        return .expiredRow
      }

      let hashMatches = approval.argsHash == ApprovalArgsHash.sha256Hex(approval.canonicalArgsJSON)
      let policyMatches = approval.policyVersion == currentPolicyVersion
      guard hashMatches, policyMatches else {
        // The recorded action no longer matches its fingerprint — reject.
        guard try Self.transitionApproval(db, id: id, on: .reject, now: now) != nil else {
          return .notPending
        }

        try Self.insertApprovalAudit(
          db,
          approval: approval,
          actor: .owner,
          action: .approvalDenied,
          decision: .stalePolicy,
          now: now
        )

        guard let rejected = try Self.fetchApproval(db, id: id) else {
          return .notPending
        }

        return .stalePolicy(rejected)
      }

      guard try Self.transitionApproval(db, id: id, on: .approve, now: now) != nil else {
        return .notPending
      }

      try Self.insertApprovalAudit(
        db,
        approval: approval,
        actor: .owner,
        action: .approvalGranted,
        decision: nil,
        now: now
      )

      guard let approved = try Self.fetchApproval(db, id: id) else {
        return .notPending
      }

      return .approved(approved)
    }
  }

  public func deny(id: Int64, decision: ApprovalDecision, now: Date) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      guard let approval = try Self.fetchApproval(db, id: id), approval.state == .pending else {
        return false
      }
      // Only expiry lands in EXPIRED; every other decision (owner reject, cancel, supersede,
      // stale policy) resolves to REJECTED — the four-state rule.
      let event: ApprovalEvent = decision == .expired ? .expire : .reject
      guard try Self.transitionApproval(db, id: id, on: event, now: now) != nil else {
        return false
      }
      // Attribute by who initiated the resolution. `.rejected` is the only
      // owner-initiated deny (the owner tapped Deny → `.owner`); every other decision reaching deny
      // is system-determined — `.expired` is the clock (a stale-button tap or the boot sweep) and,
      // defensively, `.cancelled`/`.superseded` — so it audits `.system`. Without this the boot-sweep
      // expiry path would mis-record a system action as `.owner`.
      let auditActor: AuditActor = decision == .rejected ? .owner : .system
      try Self.insertApprovalAudit(
        db,
        approval: approval,
        actor: auditActor,
        action: .approvalDenied,
        decision: decision,
        now: now
      )

      return true
    }
  }

  public func sweepExpired(now: Date) throws(StoreError) -> [Approval] {
    try database.writeMapping { db in
      let expired = try Self.fetchApprovals(
        db,
        whereClause: "state = ? AND expires_ts <= ?",
        arguments: [ApprovalState.pending.rawValue, EpochSecondCodec.epoch(now)]
      )

      var swept: [Approval] = []
      for approval in expired {
        guard try Self.transitionApproval(db, id: approval.id, on: .expire, now: now) != nil else {
          continue
        }

        try Self.insertApprovalAudit(
          db,
          approval: approval,
          actor: .system,
          action: .approvalDenied,
          decision: .expired,
          now: now
        )

        if let resolved = try Self.fetchApproval(db, id: approval.id) {
          swept.append(resolved)
        }
      }

      return swept
    }
  }

  public func unresolvedAtBoot() throws(StoreError) -> [Approval] {
    try database.readMapping { db in
      // The resolved-states arms are the crash-window belts, recognizable by the observation
      // row STILL being the placeholder — without that condition, a run parked on its SECOND
      // approval would return its first, already-executed row too, and boot would replay the
      // recorded action. REJECTED/EXPIRED rows additionally require the run to still be
      // AWAITING_APPROVAL (their deny finalization never moves the run first). APPROVED rows are
      // returned for ANY run state: an AWAITING run is the replay belt, while a run that left
      // AWAITING means the execution claim committed and the result record never landed — the
      // caller settles that claimed window in place.
      try Self.fetchApprovals(
        db,
        whereClause: """
          state = ?
          OR ((state = ?
              OR (state IN (?, ?)
                AND EXISTS (
                  SELECT 1 FROM runs WHERE runs.id = approvals.run_id AND runs.state = ?
                )))
            AND EXISTS (
              SELECT 1 FROM messages
              WHERE messages.id = approvals.observation_message_id
                AND messages.run_id = approvals.run_id
                AND messages.role = '\(MessageRole.tool.rawValue)'
                AND messages.content = ?
            ))
          """,
        arguments: [
          ApprovalState.pending.rawValue,
          ApprovalState.approved.rawValue,
          ApprovalState.rejected.rawValue,
          ApprovalState.expired.rawValue,
          RunState.awaitingApproval.rawValue,
          RunStoreGRDB.placeholderObservationContent,
        ]
      )
    }
  }

  public func resolveOrphans(now: Date) throws(StoreError) -> Int {
    try database.writeMapping { db in
      let orphans = try Self.fetchApprovals(
        db,
        whereClause: """
          state = ?
          AND EXISTS (
            SELECT 1 FROM runs WHERE runs.id = approvals.run_id AND runs.state IN (?, ?, ?, ?)
          )
          """,
        arguments: [
          ApprovalState.pending.rawValue,
          RunState.done.rawValue,
          RunState.failed.rawValue,
          RunState.cancelled.rawValue,
          RunState.superseded.rawValue,
        ]
      )

      var cleaned = 0
      for approval in orphans {
        guard try Self.transitionApproval(db, id: approval.id, on: .reject, now: now) != nil else {
          continue
        }

        try Self.insertApprovalAudit(
          db,
          approval: approval,
          actor: .system,
          action: .approvalDenied,
          decision: .cancelled,
          now: now
        )

        cleaned += 1
      }

      return cleaned
    }
  }

  public func approvalsHealth(now: Date) throws(StoreError) -> ApprovalsHealth {
    try database.readMapping { db in
      let pendingCount =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM approvals WHERE state = ?",
          arguments: [ApprovalState.pending.rawValue]
        ) ?? 0

      let oldestPendingAgeSeconds =
        try Int64.fetchOne(
          db,
          sql: "SELECT MIN(created_ts) FROM approvals WHERE state = ?",
          arguments: [ApprovalState.pending.rawValue]
        ).map { oldestEpoch in
          Int(EpochSecondCodec.epoch(now) - oldestEpoch)
        }

      return ApprovalsHealth(
        pendingCount: pendingCount,
        oldestPendingAgeSeconds: oldestPendingAgeSeconds
      )
    }
  }
}

// MARK: - Insert + Transition Seam (reused cross-store by commitSuspendedTurn)

extension ApprovalStoreGRDB {
  /// The insert every approval starts from — a PENDING row (state is store-owned, never carried on
  /// `NewApproval`). Called inside `commitSuspendedTurn`'s single transaction.
  static func insertApproval(_ db: Database, _ approval: NewApproval) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO approvals(run_id, session_id, state, tool, canonical_args, canonical_target,
          args_hash, policy_version, owner_user_id, nonce, observation_message_id, tool_call_id,
          reason, created_ts, expires_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        approval.runId,
        approval.sessionId,
        ApprovalState.pending.rawValue,
        approval.tool,
        approval.canonicalArgsJSON,
        approval.canonicalTarget,
        approval.argsHash,
        approval.policyVersion,
        approval.ownerUserId,
        approval.nonce,
        approval.observationMessageId,
        approval.toolCallId,
        approval.reason.rawValue,
        EpochSecondCodec.epoch(approval.createdTs),
        EpochSecondCodec.epoch(approval.expiresTs),
      ]
    )
    return db.lastInsertedRowID
  }

  /// The single state-change seam — mirrors `RunStoreGRDB.transitionRun`, but every legal event
  /// resolves a PENDING row to a terminal state, so `resolved_ts` is always stamped here.
  static func transitionApproval(
    _ db: Database,
    id: Int64,
    on event: ApprovalEvent,
    now: Date
  ) throws -> ApprovalState? {
    guard
      let state = try currentApprovalState(db, id: id),
      let nextState = ApprovalFSM.reduce(state: state, on: event)
    else {
      return nil
    }

    try db.execute(
      sql: "UPDATE approvals SET state = ?, resolved_ts = ? WHERE id = ?",
      arguments: [nextState.rawValue, EpochSecondCodec.epoch(now), id]
    )

    return nextState
  }

  /// Command-path resolution: CAS every PENDING approval of `runIds` → REJECTED (cancel and
  /// supersede both land in REJECTED — the four-state rule; the audit `decision` records why) and
  /// append its `approvalDenied` audit inside the CALLER's transaction (the CAS is the
  /// recorded transition). Returns the resolved ids for the coordinator signals. Reused by
  /// `CommandStoreGRDB.applyStop`/`applyNew` so the run flip and the approval CAS share one commit.
  static func resolvePendingApprovals(
    _ db: Database,
    runIds: [Int64],
    decision: ApprovalDecision,
    now: Date
  ) throws -> [Int64] {
    guard runIds.isEmpty == false else {
      return []
    }

    let placeholders = databaseQuestionMarks(count: runIds.count)
    var arguments: [any DatabaseValueConvertible] = [ApprovalState.pending.rawValue]
    arguments.append(contentsOf: runIds)
    let pending = try fetchApprovals(
      db,
      whereClause: "state = ? AND run_id IN (\(placeholders))",
      arguments: StatementArguments(arguments)
    )

    var resolved: [Int64] = []
    for approval in pending {
      guard try transitionApproval(db, id: approval.id, on: .reject, now: now) != nil else {
        continue
      }
      try insertApprovalAudit(
        db,
        approval: approval,
        actor: .owner,
        action: .approvalDenied,
        decision: decision,
        now: now
      )
      resolved.append(approval.id)
    }
    return resolved
  }
}

// MARK: - Row Mapping + Reads

private extension ApprovalStoreGRDB {
  static let selectColumns = """
    id, run_id, session_id, state, tool, canonical_args, canonical_target, args_hash,
    policy_version, owner_user_id, nonce, observation_message_id, tool_call_id, reason,
    prompt_message_id, created_ts, expires_ts, resolved_ts
    """

  static func currentApprovalState(_ db: Database, id: Int64) throws -> ApprovalState? {
    if let rawState = try String.fetchOne(
      db,
      sql: "SELECT state FROM approvals WHERE id = ?",
      arguments: [id]
    ) {
      return ApprovalState(rawValue: rawState)
    }
    return nil
  }

  static func fetchApproval(_ db: Database, id: Int64) throws -> Approval? {
    try fetchApproval(db, whereClause: "id = ?", arguments: [id])
  }

  static func fetchApproval(
    _ db: Database,
    whereClause: String,
    arguments: StatementArguments
  ) throws -> Approval? {
    if let row = try Row.fetchOne(
      db,
      sql: "SELECT \(selectColumns) FROM approvals WHERE \(whereClause)",
      arguments: arguments
    ) {
      return try mapApproval(row)
    }
    return nil
  }

  static func fetchApprovals(
    _ db: Database,
    whereClause: String,
    arguments: StatementArguments
  ) throws -> [Approval] {
    try Row.fetchAll(
      db,
      sql: "SELECT \(selectColumns) FROM approvals WHERE \(whereClause) ORDER BY id ASC",
      arguments: arguments
    )
    .map(mapApproval)
  }

  /// Fail closed on a corrupted enum column or missing epoch (same rule as `decodeItem`): a
  /// mislabeled state must never silently re-route the resolution logic.
  static func mapApproval(_ row: Row) throws -> Approval {
    guard let state = ApprovalState(rawValue: row["state"]) else {
      throw StoreError.unexpected("approvals row has an unrecognized state")
    }

    guard let reason = ApprovalReason(rawValue: row["reason"]) else {
      throw StoreError.unexpected("approvals row has an unrecognized reason")
    }

    guard
      let createdTs = EpochSecondCodec.date(fromEpoch: row["created_ts"]),
      let expiresTs = EpochSecondCodec.date(fromEpoch: row["expires_ts"])
    else {
      throw StoreError.unexpected("approvals row is missing a required timestamp")
    }

    return Approval(
      id: row["id"],
      runId: row["run_id"],
      sessionId: row["session_id"],
      state: state,
      tool: row["tool"],
      canonicalArgsJSON: row["canonical_args"],
      canonicalTarget: row["canonical_target"],
      argsHash: row["args_hash"],
      policyVersion: row["policy_version"],
      ownerUserId: row["owner_user_id"],
      nonce: row["nonce"],
      observationMessageId: row["observation_message_id"],
      toolCallId: row["tool_call_id"],
      reason: reason,
      promptMessageId: row["prompt_message_id"],
      createdTs: createdTs,
      expiresTs: expiresTs,
      resolvedTs: EpochSecondCodec.date(fromEpoch: row["resolved_ts"])
    )
  }
}

// MARK: - Same-Transaction Audit

private extension ApprovalStoreGRDB {
  /// Appends the resolution audit inside the caller's `writeMapping` transaction:
  /// the approval-state CAS is the recorded transition, so its audit rides the same commit. The
  /// decision rawValue is the `ApprovalDecision` vocabulary; a grant carries the default "ok".
  static func insertApprovalAudit(  // swiftlint:disable:this function_parameter_count
    _ db: Database,
    approval: Approval,
    actor: AuditActor,
    action: AuditAction,
    decision: ApprovalDecision?,
    now: Date
  ) throws {
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: actor,
        action: action,
        tool: approval.tool,
        decision: decision?.rawValue ?? "ok",
        runId: approval.runId,
        sessionId: approval.sessionId,
        ts: now
      )
    )
  }
}
