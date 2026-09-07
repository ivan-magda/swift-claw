import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct CoderDoneWhenTests {
  @Test func approvedTaskLeavesConversationResponsiveAndDeliversCompletion() async throws {
    // given
    let result = CoderServiceFixture.result()
    let backend = ScriptedCoderBackend(invocations: [.init(result: result)])
    let signal = OutboxSignal()
    let ordinaryReply = "Your next message reached me while the coding task is running."
    let harness = try makeSC3Harness(
      scripts: [
        [toolCallResponse([proposal])],
        [okResponse(content: "The coding task has started.")],
        [okResponse(content: ordinaryReply)],
      ],
      httpResponses: [:],
      coderBackend: backend,
      notifyOutbox: {
        signal.poke()
      }
    )
    try await harness.withJoinedCleanup(backend: backend) {
      let (id, completionRows, completionsBeforeRelease) = try await withRunningOutbox(
        harness,
        signal: signal
      ) {
        let service = try #require(harness.coderService)
        try await service.start()
        let approval = try await approveTask(in: harness)
        try #require(await backend.started.waitUntilOpen())
        let id = try #require(await backend.startedJobIDs.first)

        // when
        _ = await harness.router.handle(
          rawUpdate: textUpdate(id: 3, from: 7, text: "Can you still answer me?")
        )
        try #require(
          try await pollUntilTrue {
            try !rowIDs(containing: ordinaryReply, deliveredOnly: true, in: harness).isEmpty
          }
        )
        let replies = await harness.transport.richSends
        #expect(
          replies.contains { reply in
            reply.markdown.contains(ordinaryReply) && reply.target == .chat(7)
          }
        )
        #expect(try harness.stores.coderJobs.job(id: id)?.state == .running)
        let completionsBeforeRelease = await harness.provider.completions
        backend.allowCompletion.open()

        // then
        let completionRows = try #require(
          try await pollUntil {
            let rows = try rowIDs(containing: result.summary, deliveredOnly: true, in: harness)
            return rows.isEmpty ? nil : rows
          }
        )
        let saved = try #require(try harness.stores.coderJobs.job(id: id))
        #expect(saved.origin.runID == approval.runId)
        #expect(saved.origin.sessionID == (try harness.sessionId()))
        #expect(saved.result == result)
        #expect(saved.state == .succeeded)
        #expect(!saved.slotReserved)
        #expect(completionRows.count == 1)
        signal.poke()
        signal.finish()
        return (id, completionRows, completionsBeforeRelease)
      }
      let notices = await harness.transport.richSends.filter { send in
        send.markdown.contains(result.summary)
      }
      #expect(notices.count == 1)
      #expect(notices.first?.target == .chat(7))
      #expect(notices.first?.markdown.contains(id.uuidString) == true)
      #expect(
        try rowIDs(containing: result.summary, deliveredOnly: false, in: harness) == completionRows
      )
      #expect(await harness.provider.completions == completionsBeforeRelease)
    }
  }
}

// MARK: - Fixtures

private extension CoderDoneWhenTests {
  var proposal: ToolCall {
    ToolCall(
      id: "coder-background",
      name: CoderToolNames.submit,
      argumentsJSON: """
        {"source":{"local":{"path":"/fixture/repository-1"}},"task":"Fix retry handling",
        "workspace":"\(CoderWorkspaceMode.inPlace.rawValue)",
        "deliverable":"\(CoderDeliverable.localChanges.rawValue)","publish_existing_changes":false}
        """
    )
  }

  func approveTask(in harness: SC3Harness) async throws -> ApprovalRowSnapshot {
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 7, text: "Fix retry handling")
    )
    let approval = try #require(
      try await pollUntil {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 7, data: approveData(approval.nonce))
    )
    return approval
  }

  func rowIDs(
    containing text: String,
    deliveredOnly: Bool,
    in harness: SC3Harness
  ) throws -> [String] {
    try harness.readPool.read { database in
      try String.fetchAll(
        database,
        sql: """
          SELECT dedup_key FROM outbound_deliveries
          WHERE instr(payload, ?) > 0 AND (? = 0 OR telegram_message_id IS NOT NULL)
          ORDER BY dedup_key
          """,
        arguments: [text, deliveredOnly]
      )
    }
  }

  func withRunningOutbox<Value: Sendable>(
    _ harness: SC3Harness,
    signal: OutboxSignal,
    operation: () async throws -> Value
  ) async throws -> Value {
    let dispatcher = OutboxDispatcher(
      outbox: harness.stores.outbox,
      delivery: harness.transport,
      signal: signal,
      logger: TestLog.silent
    )
    return try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await dispatcher.run()
      }
      defer { signal.finish() }
      let value = try await operation()
      signal.finish()
      try await group.waitForAll()
      return value
    }
  }
}
