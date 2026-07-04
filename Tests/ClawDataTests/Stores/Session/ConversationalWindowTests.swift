import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ConversationalWindowTests {
  /// Seeds one session and returns (store, sessionId, writer). Rows are inserted raw so tests
  /// control ids/roles exactly.
  private func makeFixture() throws -> (
    store: SessionMessageStoreGRDB, sessionId: Int64, queue: DatabaseQueue
  ) {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let store = SessionMessageStoreGRDB(writer: queue)
    let sessionId = try store.loadOrCreateSession(sessionKey: "tg:dm:1", now: Date())
    return (store, sessionId, queue)
  }

  private func insert(
    _ queue: DatabaseQueue,
    sessionId: Int64,
    role: String,
    content: String,
    toolCalls: String? = nil,
    toolCallId: String? = nil
  ) throws -> Int64 {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts, tool_calls, tool_call_id)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId, role, content, role == "tool" ? "untrusted" : "trusted", Date(), toolCalls,
          toolCallId,
        ]
      )
      return db.lastInsertedRowID
    }
  }

  @Test func limitCountsOnlyConversationalRowsAndToolRowsRideAlong() throws {
    // given — u1, a1(anchor)+2 tool rows, u2, a2; a window of 3 conversational rows
    let fixture = try makeFixture()
    _ = try insert(fixture.queue, sessionId: fixture.sessionId, role: "user", content: "u1")
    _ = try insert(
      fixture.queue,
      sessionId: fixture.sessionId,
      role: "assistant",
      content: "",
      toolCalls: #"[{"id":"c1","name":"web_fetch","arguments":"{}"}]"#
    )
    _ = try insert(
      fixture.queue,
      sessionId: fixture.sessionId,
      role: "tool",
      content: "page text",
      toolCallId: "c1"
    )
    _ = try insert(
      fixture.queue,
      sessionId: fixture.sessionId,
      role: "tool",
      content: "more text",
      toolCallId: "c1b"
    )
    _ = try insert(fixture.queue, sessionId: fixture.sessionId, role: "user", content: "u2")
    let lastId = try insert(
      fixture.queue,
      sessionId: fixture.sessionId,
      role: "assistant",
      content: "a2"
    )

    // when
    let snapshot = try fixture.store.loadContextSnapshot(
      sessionId: fixture.sessionId,
      throughMessageId: lastId,
      limit: 3
    )

    // then — 3 conversational rows (anchor, u2, a2) plus 2 riding tool rows = 5; u1 evicted
    #expect(snapshot.history.count == 5)
    #expect(snapshot.history.first?.role == .assistant)
    #expect(snapshot.history.first?.toolCallsJSON != nil)
    #expect(snapshot.history.filter { stored in stored.role == .tool }.count == 2)
    #expect(snapshot.history.contains { stored in stored.content == "u1" } == false)
  }

  @Test func toolRowInflationCannotEvictConversationalHistory() throws {
    // given — u1, then an anchor with 30 tool rows, then a2; limit 3 conversational rows
    let fixture = try makeFixture()
    _ = try insert(fixture.queue, sessionId: fixture.sessionId, role: "user", content: "u1")
    _ = try insert(
      fixture.queue,
      sessionId: fixture.sessionId,
      role: "assistant",
      content: "",
      toolCalls: #"[{"id":"c1","name":"web_search","arguments":"{}"}]"#
    )
    for index in 1...30 {
      _ = try insert(
        fixture.queue,
        sessionId: fixture.sessionId,
        role: "tool",
        content: "obs \(index)",
        toolCallId: "c\(index)"
      )
    }
    let lastId = try insert(
      fixture.queue,
      sessionId: fixture.sessionId,
      role: "assistant",
      content: "a2"
    )

    // when
    let snapshot = try fixture.store.loadContextSnapshot(
      sessionId: fixture.sessionId,
      throughMessageId: lastId,
      limit: 3
    )

    // then — u1 still present: 3 conversational + 30 tool rows
    #expect(snapshot.history.contains { stored in stored.content == "u1" })
    #expect(snapshot.history.count == 33)
  }

  @Test func windowNeverStartsOnAToolRow() throws {
    // given — an exchange straddling the boundary: limit lands mid-exchange under the OLD cut
    let fixture = try makeFixture()
    for index in 1...5 {
      _ = try insert(
        fixture.queue,
        sessionId: fixture.sessionId,
        role: "user",
        content: "u\(index)"
      )
    }
    _ = try insert(
      fixture.queue,
      sessionId: fixture.sessionId,
      role: "assistant",
      content: "",
      toolCalls: #"[{"id":"c1","name":"web_fetch","arguments":"{}"}]"#
    )
    _ = try insert(
      fixture.queue,
      sessionId: fixture.sessionId,
      role: "tool",
      content: "obs",
      toolCallId: "c1"
    )
    let lastId = try insert(
      fixture.queue,
      sessionId: fixture.sessionId,
      role: "user",
      content: "tail"
    )

    // when — a window that would have cut between anchor and tool row by raw row count
    let snapshot = try fixture.store.loadContextSnapshot(
      sessionId: fixture.sessionId,
      throughMessageId: lastId,
      limit: 2
    )

    // then — the anchor is in-window with its tool row (boundary is conversational)
    #expect(snapshot.history.first?.role == .assistant)
    #expect(snapshot.history.count == 3)  // anchor + tool + tail
  }

  @Test func recallExcludesToolRows() throws {
    // given — a tool row and an assistant row both matching the query, in another session
    let fixture = try makeFixture()
    let otherSession = try fixture.store.loadOrCreateSession(sessionKey: "tg:dm:2", now: Date())
    _ = try insert(
      fixture.queue,
      sessionId: otherSession,
      role: "tool",
      content: "quokka page body",
      toolCallId: "c1"
    )
    _ = try insert(
      fixture.queue,
      sessionId: otherSession,
      role: "assistant",
      content: "the quokka answer"
    )
    let retriever = RetrieverGRDB(writer: fixture.queue)

    // when
    let hits = try retriever.searchRelevantMessages(
      query: "quokka",
      currentSessionId: fixture.sessionId,
      windowStartMessageId: nil,
      excludedMessageIds: [],
      limit: 10
    )

    // then — only the conversational row is recallable (§18-D)
    #expect(hits.count == 1)
    #expect(hits.first?.role == .assistant)
  }
}
