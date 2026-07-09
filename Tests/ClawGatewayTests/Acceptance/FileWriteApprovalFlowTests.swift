import ClawCore
import ClawData
import Foundation
import Testing

@testable import ClawGateway

/// The increment's first LIVE end-to-end pass over the durable fabric: a file_write proposal
/// suspends the run to a persisted checkpoint, the owner's button callback approves it, and the
/// waiter executes the RECORDED args — no fresh model turn for the gated action (§6.3).
@Suite(.serialized) struct FileWriteApprovalFlowTests {
  @Test func suspendApproveExecuteRoundTrip() async throws {
    // given — one turn: the write proposal, then the continuation reply the resume round-trip
    // consumes (an empty-toolCalls response ends the provider script)
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(
              id: "w1",
              name: "file_write",
              argumentsJSON: #"{"path":"notes/plan.md","content":"hello fabric","overwrite":false}"#
            )
          ]),
          okResponse(content: "Saved the plan."),
        ]
      ],
      httpResponses: [:]
    )

    // when — the proposal suspends the run
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write the plan"))
    let approval = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )

    // then — persisted PENDING checkpoint: approvals row + AWAITING_APPROVAL run + prompt, and
    // the file does NOT exist yet
    #expect(approval.state == ApprovalState.pending.rawValue)
    #expect(approval.tool == "file_write")
    #expect(approval.reason == ApprovalReason.askTier.rawValue)
    #expect(approval.canonicalTarget.hasSuffix("/notes/plan.md"))
    #expect(
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.awaitingApproval.rawValue
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let prompts = try await harness.waitForOutbox(atLeast: 1)
    #expect(prompts.contains { payload in payload.contains("/notes/plan.md") })

    // when — the owner taps Approve
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(
        id: 2,
        from: 7,
        data: ApprovalKeyboard.callbackData(
          nonce: approval.nonce,
          verdict: ApprovalKeyboard.approveVerdict
        )
      )
    )

    // then — the RECORDED args executed; run resumed and completed; audit trail complete
    _ = try await pollUntil(timeout: .seconds(10)) {
      FileManager.default.fileExists(atPath: approval.canonicalTarget) ? true : nil
    }
    #expect(
      try String(contentsOfFile: approval.canonicalTarget, encoding: .utf8) == "hello fabric"
    )
    _ = try await pollUntil(timeout: .seconds(10)) {
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.done.rawValue ? true : nil
    }
    let resolved = try fetchApprovals(databasePath: harness.databasePath)
    #expect(resolved.map(\.state) == [ApprovalState.approved.rawValue])
    let payloads = try await harness.waitForOutbox(atLeast: 2)
    #expect(payloads.contains { payload in payload.contains("Saved the plan.") })
    let audits = try harness.auditRows()
    #expect(audits.contains { row in row.action == AuditAction.approvalRequested.rawValue })
    #expect(audits.contains { row in row.action == AuditAction.approvalGranted.rawValue })
  }

  @Test func denyResolvesWithASyntheticObservationAndNoWrite() async throws {
    // given
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(
              id: "w1",
              name: "file_write",
              argumentsJSON: #"{"path":"notes/plan.md","content":"hello","overwrite":false}"#
            )
          ])
        ]
      ],
      httpResponses: [:]
    )
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write it"))
    let approval = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )

    // when — the owner taps Deny
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(
        id: 2,
        from: 7,
        data: ApprovalKeyboard.callbackData(
          nonce: approval.nonce,
          verdict: ApprovalKeyboard.denyVerdict
        )
      )
    )

    // then — REJECTED row, FAILED run, no file, owner notice, audit decision "rejected"
    _ = try await pollUntil(timeout: .seconds(10)) {
      try fetchApprovals(databasePath: harness.databasePath).first?.state
        == ApprovalState.rejected.rawValue ? true : nil
    }
    _ = try await pollUntil(timeout: .seconds(10)) {
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.failed.rawValue ? true : nil
    }
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let audits = try harness.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.rejected.rawValue
      }
    )
  }
}
