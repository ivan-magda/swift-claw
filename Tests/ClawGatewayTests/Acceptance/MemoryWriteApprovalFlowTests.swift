import ClawCore
import ClawData
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite(.serialized) struct MemoryWriteApprovalFlowTests {
  @Test func suspendApproveInsertsExactlyOneAssistantItem() async throws {
    // given — a proposal whose text trips the secret-shape scan (§8.2 warning surfacing)
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(
              id: "m1",
              name: "memory_write",
              argumentsJSON: #"{"text":"the api_key lives in 1Password","kind":"reference"}"#
            )
          ]),
          okResponse(content: "Noted durably."),
        ]
      ],
      httpResponses: [:]
    )

    // when — the proposal suspends
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "remember that"))
    let approval = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )

    // then — the prompt carries the scan warning AND the verbatim preview (§5.4/§8.2)
    #expect(approval.tool == "memory_write")
    #expect(approval.canonicalTarget.hasPrefix("memory_item:reference:"))
    let prompts = try await harness.waitForOutbox(atLeast: 1)
    let prompt = try #require(prompts.last)
    #expect(prompt.contains("possible secret-shaped text"))
    #expect(prompt.contains("the api_key lives in 1Password"))

    // when — approve
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

    // then — exactly one assistant-sourced item; run resumed to DONE
    let items = try #require(
      // swiftlint:disable:next discouraged_optional_collection
      await pollUntil(timeout: .seconds(10)) { () throws -> [Row]? in
        let pool = try ClawDatabase.makePool(path: harness.databasePath)
        let rows = try pool.read { db in
          try Row.fetchAll(db, sql: "SELECT text, source, kind FROM memory_items")
        }
        return rows.isEmpty ? nil : rows
      }
    )
    #expect(items.count == 1)
    #expect(items.first?["source"] == "assistant")
    #expect(items.first?["kind"] == "reference")
    _ = try await pollUntilTrue(timeout: .seconds(10)) {
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.done.rawValue
    }
  }
}
