import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ApprovalStoreGRDBTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let store: ApprovalStoreGRDB
  }

  /// Fresh in-memory DB with one session (id 1). Runs are seeded per-test so their state is
  /// exactly what each boot/orphan scenario needs.
  private func makeFixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:7', ?, ?, 0)
          """,
        arguments: [Date(), Date()]
      )
    }
    return Fixture(queue: queue, store: ApprovalStoreGRDB(writer: queue))
  }

  /// Inserts a run in the given state and returns its id (approvals.run_id has an FK to runs).
  private func seedRun(_ queue: DatabaseQueue, state: RunState = .running) throws -> Int64 {
    try queue.write { db in
      try db.execute(
        sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (1, ?, ?, ?)",
        arguments: [state.rawValue, Date(), Date()]
      )
      return db.lastInsertedRowID
    }
  }

  /// Inserts an observation row for the run: placeholder content models a crash-window row
  /// (waiter commit never landed); any other content models an already-executed approval.
  private func seedObservation(
    _ queue: DatabaseQueue,
    runId: Int64,
    content: String = "awaiting owner approval"
  ) throws -> Int64 {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (1, ?, 'tool', ?, 'untrusted', ?, 'c1')
          """,
        arguments: [runId, content, Date()]
      )
      return db.lastInsertedRowID
    }
  }

  private func makeNewApproval(
    runId: Int64,
    nonce: String = "nonce-a",
    canonicalArgsJSON: String = #"{"path":"/w/plan.md"}"#,
    policyVersion: String = "pv16",
    observationMessageId: Int64 = 1,
    createdTs: Date,
    expiresTs: Date
  ) -> NewApproval {
    NewApproval(
      runId: runId,
      sessionId: 1,
      tool: "file_write",
      canonicalArgsJSON: canonicalArgsJSON,
      canonicalTarget: "/w/plan.md",
      argsHash: ApprovalArgsHash.sha256Hex(canonicalArgsJSON),
      policyVersion: policyVersion,
      ownerUserId: 7,
      nonce: nonce,
      observationMessageId: observationMessageId,
      toolCallId: "c1",
      reason: .askTier,
      createdTs: createdTs,
      expiresTs: expiresTs
    )
  }

  @discardableResult
  private func insert(_ queue: DatabaseQueue, _ newApproval: NewApproval) throws -> Int64 {
    try queue.write { db in try ApprovalStoreGRDB.insertApproval(db, newApproval) }
  }

  private struct AuditLine: Equatable {
    let actor: String
    let action: String
    let decision: String
  }

  private func audits(_ queue: DatabaseQueue) throws -> [AuditLine] {
    try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT actor, action, decision FROM audit_events ORDER BY id")
        .map { row in
          AuditLine(actor: row["actor"], action: row["action"], decision: row["decision"])
        }
    }
  }

  @Test func insertStartsPendingAndRoundTripsEveryColumn() throws {
    // given
    let env = try makeFixture()
    let runId = try seedRun(env.queue)
    let created = Date(timeIntervalSince1970: 1_782_000_000)
    let expires = Date(timeIntervalSince1970: 1_782_003_600)

    // when
    let id = try insert(
      env.queue,
      makeNewApproval(runId: runId, createdTs: created, expiresTs: expires)
    )

    // then — the state is store-owned (always PENDING) and the epoch columns decode back exactly
    let approval = try #require(try env.store.approval(id: id))
    #expect(approval.state == .pending)
    #expect(approval.tool == "file_write")
    #expect(approval.reason == .askTier)
    #expect(approval.canonicalArgsJSON == #"{"path":"/w/plan.md"}"#)
    #expect(approval.argsHash == ApprovalArgsHash.sha256Hex(#"{"path":"/w/plan.md"}"#))
    #expect(approval.createdTs == created)
    #expect(approval.expiresTs == expires)
    #expect(approval.resolvedTs == nil)
    #expect(approval.promptMessageId == nil)
  }

  @Test func approvalByNonceFindsTheRowAndMissesUnknown() throws {
    // given
    let env = try makeFixture()
    let runId = try seedRun(env.queue)
    let now = Date()
    try insert(
      env.queue,
      makeNewApproval(
        runId: runId,
        nonce: "n-77",
        createdTs: now,
        expiresTs: now.addingTimeInterval(60)
      )
    )

    // when / then — lookup is by nonce ONLY (never by id)
    #expect(try env.store.approval(nonce: "n-77")?.nonce == "n-77")
    #expect(try env.store.approval(nonce: "does-not-exist") == nil)
  }

  @Test func approveCommitsWhenHashAndPolicyMatch() throws {
    // given
    let env = try makeFixture()
    let runId = try seedRun(env.queue)
    let now = Date()
    let id = try insert(
      env.queue,
      makeNewApproval(
        runId: runId,
        policyVersion: "pv16",
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )

    // when
    let outcome = try env.store.approve(
      id: id,
      currentPolicyVersion: "pv16",
      openTurnWindow: false,
      now: now
    )

    // then — PENDING→APPROVED, resolved_ts stamped, approvalGranted audited in the same txn
    guard case .approved(let approved) = outcome else {
      Issue.record("expected .approved, got \(outcome)")
      return
    }
    #expect(approved.state == .approved)
    #expect(approved.resolvedTs != nil)  // resolved_ts stamped (epoch codec rounds to the second)
    #expect(try env.store.approval(id: id)?.state == .approved)
    #expect(
      try audits(env.queue) == [
        AuditLine(
          actor: AuditActor.owner.rawValue,
          action: AuditAction.approvalGranted.rawValue,
          decision: "ok"
        )
      ]
    )
  }

  @Test func approveRejectsOnArgsHashMismatch() throws {
    // given — the stored args_hash no longer matches SHA-256(canonical_args): tampered row
    let env = try makeFixture()
    let runId = try seedRun(env.queue)
    let now = Date()
    let id = try insert(
      env.queue,
      makeNewApproval(runId: runId, createdTs: now, expiresTs: now.addingTimeInterval(3600))
    )
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE approvals SET args_hash = 'tampered' WHERE id = ?",
        arguments: [id]
      )
    }

    // when
    let outcome = try env.store.approve(
      id: id,
      currentPolicyVersion: "pv16",
      openTurnWindow: false,
      now: now
    )

    // then — PENDING→REJECTED, decision stale_policy, approvalDenied audited
    guard case .stalePolicy(let rejected) = outcome else {
      Issue.record("expected .stalePolicy, got \(outcome)")
      return
    }
    #expect(rejected.state == .rejected)
    #expect(try env.store.approval(id: id)?.state == .rejected)
    #expect(
      try audits(env.queue) == [
        AuditLine(
          actor: AuditActor.owner.rawValue,
          action: AuditAction.approvalDenied.rawValue,
          decision: ApprovalDecision.stalePolicy.rawValue
        )
      ]
    )
  }

  @Test func approveRejectsOnPolicyVersionMismatch() throws {
    // given — args match, but the recomputed policy_version drifted
    let env = try makeFixture()
    let runId = try seedRun(env.queue)
    let now = Date()
    let id = try insert(
      env.queue,
      makeNewApproval(
        runId: runId,
        policyVersion: "pv16",
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )

    // when
    let outcome = try env.store.approve(
      id: id,
      currentPolicyVersion: "pv99",
      openTurnWindow: false,
      now: now
    )

    // then
    guard case .stalePolicy = outcome else {
      Issue.record("expected .stalePolicy, got \(outcome)")
      return
    }
    #expect(try env.store.approval(id: id)?.state == .rejected)
  }

  @Test func approveOfAnAlreadyResolvedRowIsNotPending() throws {
    // given — a row already denied (duplicate-tap scenario)
    let env = try makeFixture()
    let runId = try seedRun(env.queue)
    let now = Date()
    let id = try insert(
      env.queue,
      makeNewApproval(runId: runId, createdTs: now, expiresTs: now.addingTimeInterval(3600))
    )
    #expect(try env.store.deny(id: id, decision: .rejected, now: now))

    // when
    let outcome = try env.store.approve(
      id: id,
      currentPolicyVersion: "pv16",
      openTurnWindow: false,
      now: now
    )

    // then — the second tap is a no-op the caller answers "already handled"
    #expect(outcome == .notPending)
    #expect(try env.store.approval(id: id)?.state == .rejected)
  }

  @Test func approveOfAnExpiredPendingRowReturnsExpiredRowUntouched() throws {
    // given — expires_ts already passed while still PENDING
    let env = try makeFixture()
    let runId = try seedRun(env.queue)
    let now = Date()
    let id = try insert(
      env.queue,
      makeNewApproval(
        runId: runId,
        createdTs: now.addingTimeInterval(-7200),
        expiresTs: now.addingTimeInterval(-3600)
      )
    )

    // when
    let outcome = try env.store.approve(
      id: id,
      currentPolicyVersion: "pv16",
      openTurnWindow: false,
      now: now
    )

    // then — the caller routes to the deny path; the row stays PENDING and nothing is audited
    #expect(outcome == .expiredRow)
    #expect(try env.store.approval(id: id)?.state == .pending)
    #expect(try audits(env.queue).isEmpty)
  }

  @Test func approveOpensTheTurnWindowInTheSameTransaction() throws {
    // given — a parked run whose approval the owner will widen to the whole turn
    let env = try makeFixture()
    let runId = try seedRun(env.queue, state: .awaitingApproval)
    let now = Date()
    let id = try insert(
      env.queue,
      makeNewApproval(runId: runId, createdTs: now, expiresTs: now.addingTimeInterval(3600))
    )

    // when
    let outcome = try env.store.approve(
      id: id,
      currentPolicyVersion: "pv16",
      openTurnWindow: true,
      now: now
    )

    // then — the grant and the window landed together
    guard case .approved = outcome else {
      Issue.record("expected .approved, got \(outcome)")
      return
    }
    #expect(try RunStoreGRDB(writer: env.queue).isAutoApproveWindowOpen(runId: runId))
  }

  @Test func aPlainApproveLeavesTheTurnWindowClosed() throws {
    // given
    let env = try makeFixture()
    let runId = try seedRun(env.queue, state: .awaitingApproval)
    let now = Date()
    let id = try insert(
      env.queue,
      makeNewApproval(runId: runId, createdTs: now, expiresTs: now.addingTimeInterval(3600))
    )

    // when
    _ = try env.store.approve(
      id: id,
      currentPolicyVersion: "pv16",
      openTurnWindow: false,
      now: now
    )

    // then — approving one action never widens the turn
    #expect(try RunStoreGRDB(writer: env.queue).isAutoApproveWindowOpen(runId: runId) == false)
  }

  @Test(arguments: ["pv99", "tampered-hash", "expired"])
  func aGuardFailureLeavesTheTurnWindowClosed(_ failure: String) throws {
    // given — the widening verdict rides a row that fails one of the CAS guards
    let env = try makeFixture()
    let runId = try seedRun(env.queue, state: .awaitingApproval)
    let now = Date()
    let expired = failure == "expired"
    let id = try insert(
      env.queue,
      makeNewApproval(
        runId: runId,
        createdTs: now.addingTimeInterval(expired ? -7200 : 0),
        expiresTs: now.addingTimeInterval(expired ? -3600 : 3600)
      )
    )
    if failure == "tampered-hash" {
      try env.queue.write { db in
        try db.execute(
          sql: "UPDATE approvals SET args_hash = 'tampered' WHERE id = ?",
          arguments: [id]
        )
      }
    }

    // when
    let outcome = try env.store.approve(
      id: id,
      currentPolicyVersion: failure == "pv99" ? "pv99" : "pv16",
      openTurnWindow: true,
      now: now
    )

    // then — no grant, so no window: the widening cannot outlive the guard that refused it
    if case .approved = outcome {
      Issue.record("expected the guard to refuse the grant, got \(outcome)")
    }
    #expect(try RunStoreGRDB(writer: env.queue).isAutoApproveWindowOpen(runId: runId) == false)
  }

  @Test func denyCommitsRejectedAndAudits() throws {
    // given
    let env = try makeFixture()
    let runId = try seedRun(env.queue)
    let now = Date()
    let id = try insert(
      env.queue,
      makeNewApproval(runId: runId, createdTs: now, expiresTs: now.addingTimeInterval(3600))
    )

    // when
    let resolved = try env.store.deny(id: id, decision: .cancelled, now: now)

    // then — PENDING→REJECTED (cancel/supersede resolve to REJECTED; decision records why)
    #expect(resolved)
    #expect(try env.store.approval(id: id)?.state == .rejected)
    #expect(
      try audits(env.queue) == [
        AuditLine(
          actor: AuditActor.system.rawValue,
          action: AuditAction.approvalDenied.rawValue,
          decision: ApprovalDecision.cancelled.rawValue
        )
      ]
    )
  }

  @Test func denyWithExpiredDecisionMovesToExpired() throws {
    // given
    let env = try makeFixture()
    let runId = try seedRun(env.queue)
    let now = Date()
    let id = try insert(
      env.queue,
      makeNewApproval(runId: runId, createdTs: now, expiresTs: now.addingTimeInterval(3600))
    )

    // when — the .expired decision alone routes PENDING→EXPIRED (all others → REJECTED)
    #expect(try env.store.deny(id: id, decision: .expired, now: now))

    // then
    #expect(try env.store.approval(id: id)?.state == .expired)
  }

  @Test func denyLosesTheRaceWhenAlreadyResolved() throws {
    // given — a racing resolver already moved the row
    let env = try makeFixture()
    let runId = try seedRun(env.queue)
    let now = Date()
    let id = try insert(
      env.queue,
      makeNewApproval(runId: runId, createdTs: now, expiresTs: now.addingTimeInterval(3600))
    )
    #expect(try env.store.deny(id: id, decision: .rejected, now: now))

    // when / then — the second deny observes a non-PENDING row and reports the loss
    #expect(try env.store.deny(id: id, decision: .cancelled, now: now) == false)
  }

  @Test func sweepExpiredMovesOnlyThePastDuePendingRows() throws {
    // given — two runs: one approval already expired, one still live (distinct runs so the
    // partial UNIQUE-PENDING index permits both)
    let env = try makeFixture()
    let expiredRun = try seedRun(env.queue)
    let liveRun = try seedRun(env.queue)
    let now = Date()
    let expiredId = try insert(
      env.queue,
      makeNewApproval(
        runId: expiredRun,
        nonce: "n-expired",
        createdTs: now.addingTimeInterval(-7200),
        expiresTs: now.addingTimeInterval(-60)
      )
    )
    let liveId = try insert(
      env.queue,
      makeNewApproval(
        runId: liveRun,
        nonce: "n-live",
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )

    // when
    let swept = try env.store.sweepExpired(now: now)

    // then — only the past-due row sweeps; each swept row is EXPIRED + audited decision expired
    #expect(swept.map(\.id) == [expiredId])
    #expect(swept.allSatisfy { row in row.state == .expired })
    #expect(try env.store.approval(id: expiredId)?.state == .expired)
    #expect(try env.store.approval(id: liveId)?.state == .pending)
    #expect(
      try audits(env.queue) == [
        AuditLine(
          actor: AuditActor.system.rawValue,
          action: AuditAction.approvalDenied.rawValue,
          decision: ApprovalDecision.expired.rawValue
        )
      ]
    )
  }
}

// MARK: - Boot Reconciliation

extension ApprovalStoreGRDBTests {
  @Test func unresolvedAtBootReturnsPendingAndAwaitingApprovedRows() throws {
    // given — a PENDING row, an APPROVED row whose run is AWAITING_APPROVAL (§6.5 crash window),
    // and an APPROVED row whose run already reached DONE (settled — must be excluded)
    let env = try makeFixture()
    let pendingRun = try seedRun(env.queue, state: .awaitingApproval)
    let crashRun = try seedRun(env.queue, state: .awaitingApproval)
    let settledRun = try seedRun(env.queue, state: .done)
    let now = Date()
    let pendingId = try insert(
      env.queue,
      makeNewApproval(
        runId: pendingRun,
        nonce: "n-pending",
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )
    let crashId = try insert(
      env.queue,
      makeNewApproval(
        runId: crashRun,
        nonce: "n-crash",
        observationMessageId: try seedObservation(env.queue, runId: crashRun),
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )
    let settledId = try insert(
      env.queue,
      makeNewApproval(
        runId: settledRun,
        nonce: "n-settled",
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE approvals SET state = 'APPROVED' WHERE id IN (?, ?)",
        arguments: [crashId, settledId]
      )
    }

    // when
    let unresolved = try env.store.unresolvedAtBoot()

    // then
    #expect(Set(unresolved.map(\.id)) == Set([pendingId, crashId]))
  }

  @Test func unresolvedAtBootReturnsApprovedClaimedRowsWhoseRunLeftAwaiting() throws {
    // given — the claimed crash window: the approve CAS and the execution claim committed (run
    // flipped off AWAITING, later orphan-failed at boot) but the result record never landed, so
    // the observation is still the placeholder. A filled twin on the same shape must stay excluded.
    let env = try makeFixture()
    let claimedRun = try seedRun(env.queue, state: .failed)
    let recordedRun = try seedRun(env.queue, state: .failed)
    let now = Date()
    let claimedId = try insert(
      env.queue,
      makeNewApproval(
        runId: claimedRun,
        nonce: "n-claimed",
        observationMessageId: try seedObservation(env.queue, runId: claimedRun),
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )
    let recordedId = try insert(
      env.queue,
      makeNewApproval(
        runId: recordedRun,
        nonce: "n-recorded",
        observationMessageId: try seedObservation(
          env.queue,
          runId: recordedRun,
          content: "Wrote 12 B to /w/plan.md (created)."
        ),
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE approvals SET state = 'APPROVED' WHERE id IN (?, ?)",
        arguments: [claimedId, recordedId]
      )
    }

    // when
    let unresolved = try env.store.unresolvedAtBoot()

    // then — the claimed row surfaces for boot settlement; the recorded one is already done
    #expect(unresolved.map(\.id) == [claimedId])
  }

  @Test func unresolvedAtBootExcludesResolvedRowsWhoseObservationIsFilled() throws {
    // given — the multi-suspend shape: ONE run, approval #1 APPROVED with its observation already
    // filled (executed before the restart), approval #2 PENDING on a fresh placeholder. Re-parking
    // #1 would re-execute its recorded action and steal #2's park (§6.5 is for crash windows only).
    let env = try makeFixture()
    let run = try seedRun(env.queue, state: .awaitingApproval)
    let now = Date()
    let executedId = try insert(
      env.queue,
      makeNewApproval(
        runId: run,
        nonce: "n-executed",
        observationMessageId: try seedObservation(
          env.queue,
          runId: run,
          content: "Wrote 12 B to /w/plan.md (created)."
        ),
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )
    // Resolve #1 BEFORE inserting #2 — the UNIQUE partial index allows one PENDING row per run.
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE approvals SET state = 'APPROVED' WHERE id = ?",
        arguments: [executedId]
      )
    }
    let parkedId = try insert(
      env.queue,
      makeNewApproval(
        runId: run,
        nonce: "n-parked",
        observationMessageId: try seedObservation(env.queue, runId: run),
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )

    // when
    let unresolved = try env.store.unresolvedAtBoot()

    // then — only the still-parked placeholder approval comes back
    #expect(unresolved.map(\.id) == [parkedId])
  }

  @Test func unresolvedAtBootReturnsDeniedRowsOnlyOnAwaitingRuns() throws {
    // given — the deny-side crash window: REJECTED and EXPIRED rows whose run is still
    // AWAITING_APPROVAL (the deny CAS committed, the waiter's run-fail commit did not), plus the
    // same denied states on terminal runs (settled — must be excluded)
    let env = try makeFixture()
    let rejectedAwaitingRun = try seedRun(env.queue, state: .awaitingApproval)
    let expiredAwaitingRun = try seedRun(env.queue, state: .awaitingApproval)
    let rejectedFailedRun = try seedRun(env.queue, state: .failed)
    let expiredCancelledRun = try seedRun(env.queue, state: .cancelled)
    let now = Date()
    let rejectedAwaitingId = try insert(
      env.queue,
      makeNewApproval(
        runId: rejectedAwaitingRun,
        nonce: "n-rej-awaiting",
        observationMessageId: try seedObservation(env.queue, runId: rejectedAwaitingRun),
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )
    let expiredAwaitingId = try insert(
      env.queue,
      makeNewApproval(
        runId: expiredAwaitingRun,
        nonce: "n-exp-awaiting",
        observationMessageId: try seedObservation(env.queue, runId: expiredAwaitingRun),
        createdTs: now.addingTimeInterval(-7200),
        expiresTs: now.addingTimeInterval(-60)
      )
    )
    let rejectedFailedId = try insert(
      env.queue,
      makeNewApproval(
        runId: rejectedFailedRun,
        nonce: "n-rej-failed",
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )
    let expiredCancelledId = try insert(
      env.queue,
      makeNewApproval(
        runId: expiredCancelledRun,
        nonce: "n-exp-cancelled",
        createdTs: now.addingTimeInterval(-7200),
        expiresTs: now.addingTimeInterval(-60)
      )
    )
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE approvals SET state = 'REJECTED' WHERE id IN (?, ?)",
        arguments: [rejectedAwaitingId, rejectedFailedId]
      )
      try db.execute(
        sql: "UPDATE approvals SET state = 'EXPIRED' WHERE id IN (?, ?)",
        arguments: [expiredAwaitingId, expiredCancelledId]
      )
    }

    // when
    let unresolved = try env.store.unresolvedAtBoot()

    // then — only the AWAITING_APPROVAL-run rows come back; terminal-run denials stay settled
    #expect(Set(unresolved.map(\.id)) == Set([rejectedAwaitingId, expiredAwaitingId]))
  }

  @Test func resolveOrphansRejectsPendingRowsOfTerminalRuns() throws {
    // given — a PENDING approval whose run FAILED (orphan) and one whose run is still parked
    let env = try makeFixture()
    let terminalRun = try seedRun(env.queue, state: .failed)
    let parkedRun = try seedRun(env.queue, state: .awaitingApproval)
    let now = Date()
    let orphanId = try insert(
      env.queue,
      makeNewApproval(
        runId: terminalRun,
        nonce: "n-orphan",
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )
    let keptId = try insert(
      env.queue,
      makeNewApproval(
        runId: parkedRun,
        nonce: "n-kept",
        createdTs: now,
        expiresTs: now.addingTimeInterval(3600)
      )
    )

    // when
    let cleaned = try env.store.resolveOrphans(now: now)

    // then — only the terminal-run orphan is rejected; the parked one is left for the re-park
    #expect(cleaned == 1)
    #expect(try env.store.approval(id: orphanId)?.state == .rejected)
    #expect(try env.store.approval(id: keptId)?.state == .pending)
    #expect(
      try audits(env.queue) == [
        AuditLine(
          actor: AuditActor.system.rawValue,
          action: AuditAction.approvalDenied.rawValue,
          decision: ApprovalDecision.cancelled.rawValue
        )
      ]
    )
  }
}

// MARK: - Health + Store Wiring

extension ApprovalStoreGRDBTests {
  @Test func approvalsHealthCountsPendingAndOldestAge() throws {
    // given — two PENDING rows on distinct runs; the older created 300 s before now
    let env = try makeFixture()
    let firstRun = try seedRun(env.queue)
    let secondRun = try seedRun(env.queue)
    let now = Date(timeIntervalSince1970: 1_782_000_300)
    try insert(
      env.queue,
      makeNewApproval(
        runId: firstRun,
        nonce: "n-old",
        createdTs: Date(timeIntervalSince1970: 1_782_000_000),
        expiresTs: Date(timeIntervalSince1970: 1_782_003_600)
      )
    )
    try insert(
      env.queue,
      makeNewApproval(
        runId: secondRun,
        nonce: "n-new",
        createdTs: Date(timeIntervalSince1970: 1_782_000_200),
        expiresTs: Date(timeIntervalSince1970: 1_782_003_600)
      )
    )

    // when
    let health = try env.store.approvalsHealth(now: now)

    // then
    #expect(health.pendingCount == 2)
    #expect(health.oldestPendingAgeSeconds == 300)
  }

  @Test func approvalsHealthIsZeroWhenNothingPending() throws {
    // given
    let env = try makeFixture()

    // when
    let health = try env.store.approvalsHealth(now: Date())

    // then
    #expect(health.pendingCount == 0)
    #expect(health.oldestPendingAgeSeconds == nil)
  }

  @Test func openStoresExposesTheApprovalStore() throws {
    // given — the composed store bundle, wired through openStores on a real file DB
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-approvals-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let stores = try ClawDatabase.openStores(path: path)

    // when / then — the protocol-typed store is reachable and functional
    #expect(try stores.approvals.approvalsHealth(now: Date()).pendingCount == 0)
  }
}
