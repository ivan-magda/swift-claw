import ClawCore
import ClawData
import Foundation
import Testing

@testable import ClawGateway

/// The increment KEYSTONE (spec §1/§10). Seven forged-or-invalid callbacks — non-allowlisted sender,
/// different allowlisted non-owner, unknown nonce, duplicate tap after resolution, expired row,
/// tampered args-hash, stale policy_version — each DENY and CANNOT drive the row to APPROVED. Every
/// clause proves it on the persisted `approvals`/`runs`/`audit_events` rows (A4: the primary proof)
/// and, for the auth-failure clauses, the neutral-toast `answerCallbackQuery` spy (secondary).
@Suite(.serialized) struct CallbackAuthMatrixTests {
  // MARK: - Fixture

  private func grantAudited(_ harness: SC3Harness) throws -> Bool {
    try harness.auditRows().contains { row in
      row.action == AuditAction.approvalGranted.rawValue
    }
  }

  // MARK: - Auth-chain denials (row untouched, audited message_in/forbidden)

  @Test func forgedNonAllowlistedSenderCannotApprove() async throws {
    // given — a live PENDING approval owned by user 7
    let (harness, approval) = try await suspendFileWrite()

    // when — a NON-allowlisted user taps Approve with the real nonce
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 999, data: approveData(approval.nonce))
    )

    // then — the row is untouched, nothing executed, and the attempt is a forbidden ACCESS event
    // (not an approval decision) attributed to `system` — a stranger's tap is never owner-attributed;
    // the callback is answered with a neutral toast (A4, secondary)
    #expect(
      try fetchApprovals(databasePath: harness.databasePath).map(\.state)
        == [ApprovalState.pending.rawValue]
    )
    #expect(
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.awaitingApproval.rawValue
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let audits = try harness.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.messageIn.rawValue && row.decision == "forbidden"
          && row.actor == AuditActor.system.rawValue
      }
    )
    #expect(try grantAudited(harness) == false)
    // A4 toast spy — the RecordingTransport recording Task 21 Step 5 added. Toasts are the
    // SECONDARY proof; the persisted rows above are primary.
    await harness.transport.waitForAnswers(atLeast: 1)
    #expect(await harness.transport.answeredCallbacks.isEmpty == false)
  }

  @Test func differentAllowlistedNonOwnerCannotApprove() async throws {
    // given — user 8 is allowlisted too, but the approval's owner is 7 (§4.4 owner binding)
    let (harness, approval) = try await suspendFileWrite()
    try harness.stores.allowlist.seedAllowlist(userIds: [8])

    // when
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 8, data: approveData(approval.nonce))
    )

    // then — owner-binding fails closed: row untouched, run still parked, forbidden access event
    // attributed to `system` (the resolved row's owner is 7, not the sender), no grant
    #expect(
      try fetchApprovals(databasePath: harness.databasePath).map(\.state)
        == [ApprovalState.pending.rawValue]
    )
    #expect(
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.awaitingApproval.rawValue
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let audits = try harness.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.messageIn.rawValue && row.decision == "forbidden"
          && row.actor == AuditActor.system.rawValue
      }
    )
    #expect(try grantAudited(harness) == false)
  }

  @Test func unknownNonceCannotApprove() async throws {
    // given
    let (harness, approval) = try await suspendFileWrite()

    // when — the owner taps, but the callback carries a nonce no approval row owns
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 7, data: approveData("AAAAAAAAAAAAAAAAAAAAAA"))
    )

    // then — nothing resolves; the real row stays PENDING and the run stays parked; audited
    // forbidden with actor `system`: owner-attribution requires the RESOLVED approval row
    // (`approval.ownerUserId == sender`, the handler's only owner identity), and an unknown nonce
    // resolves no row — so even the owner's tap audits as `system` here (Task 15 denyAuth contract)
    #expect(
      try fetchApprovals(databasePath: harness.databasePath).map(\.state)
        == [ApprovalState.pending.rawValue]
    )
    #expect(
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.awaitingApproval.rawValue
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let audits = try harness.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.messageIn.rawValue && row.decision == "forbidden"
          && row.actor == AuditActor.system.rawValue
      }
    )
    #expect(try grantAudited(harness) == false)
  }

  // MARK: - Resolution-state denials (single-use CAS + validate-in-CAS)

  @Test func duplicateTapAfterResolutionIsANoOp() async throws {
    // given — a legitimate approve lands first
    let (harness, approval) = try await suspendFileWrite()
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 7, data: approveData(approval.nonce))
    )
    _ = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first?.state
          == ApprovalState.approved.rawValue ? true : nil
      }
    )

    // when — the owner taps the SAME nonce again (the nonce is never consumed/deleted)
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 3, from: 7, data: approveData(approval.nonce))
    )

    // then — the duplicate resolves nothing new: still one APPROVED row, exactly one grant audit
    #expect(
      try fetchApprovals(databasePath: harness.databasePath).map(\.state)
        == [ApprovalState.approved.rawValue]
    )
    let grants = try harness.auditRows().filter { row in
      row.action == AuditAction.approvalGranted.rawValue
    }
    #expect(grants.count == 1)
  }

  @Test func expiredRowCannotApprove() async throws {
    // given — the deadline has already passed while the row is still PENDING
    let (harness, approval) = try await suspendFileWrite()
    try tamperApproval(
      databasePath: harness.databasePath,
      id: approval.id,
      column: "expires_ts",
      value: Int64(1)  // epoch seconds — the store's on-disk timestamp encoding
    )

    // when — the owner taps Approve
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 7, data: approveData(approval.nonce))
    )

    // then — the approve CAS sees an expired row and routes to the deny path: EXPIRED → run FAILED,
    // audited approval_denied/expired; the recorded args never execute
    _ = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first?.state
          == ApprovalState.expired.rawValue ? true : nil
      }
    )
    _ = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try runState(databasePath: harness.databasePath, runId: approval.runId)
          == RunState.failed.rawValue ? true : nil
      }
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let audits = try harness.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.expired.rawValue
      }
    )
    #expect(try grantAudited(harness) == false)
  }

  @Test func tamperedArgsHashCannotApprove() async throws {
    // given — the recorded canonical args are MUTATED after park (a re-proposed variant), so the
    // stored args-hash no longer matches SHA-256(canonical_args). This clause pins the recorded-args
    // binding: an approved execution runs exactly the bytes the owner was shown, and any post-park
    // mutation breaks the fingerprint before it can ever reach APPROVED.
    let (harness, approval) = try await suspendFileWrite()
    let variantTarget = harness.workspaceRoot.appendingPathComponent("notes/evil.md").path
    try tamperApproval(
      databasePath: harness.databasePath,
      id: approval.id,
      column: "canonical_args",
      value: #"{"path":"notes/evil.md","content":"EXFILTRATED","overwrite":true}"#
    )

    // when
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 7, data: approveData(approval.nonce))
    )

    // then — the approve guard commits PENDING → REJECTED / stale_policy; run FAILED; neither the
    // originally-recorded target nor the re-proposed variant is ever written
    _ = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first?.state
          == ApprovalState.rejected.rawValue ? true : nil
      }
    )
    _ = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try runState(databasePath: harness.databasePath, runId: approval.runId)
          == RunState.failed.rawValue ? true : nil
      }
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    #expect(FileManager.default.fileExists(atPath: variantTarget) == false)
    let audits = try harness.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.stalePolicy.rawValue
      }
    )
    #expect(try grantAudited(harness) == false)
  }

  @Test func stalePolicyVersionCannotApprove() async throws {
    // given — the run's tools/prompt/config effectively changed since the request
    let (harness, approval) = try await suspendFileWrite()
    try tamperApproval(
      databasePath: harness.databasePath,
      id: approval.id,
      column: "policy_version",
      value: "ffffffffffffffff"
    )

    // when
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 7, data: approveData(approval.nonce))
    )

    // then — recomputed policy_version ≠ stored → REJECTED / stale_policy; no write
    _ = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first?.state
          == ApprovalState.rejected.rawValue ? true : nil
      }
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let audits = try harness.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.stalePolicy.rawValue
      }
    )
    #expect(try grantAudited(harness) == false)
  }
}
