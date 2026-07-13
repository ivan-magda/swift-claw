import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ExchangeCommitTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let sessionId: Int64
    let runId: Int64
  }

  /// One RUNNING run with its inbound user message, ready to commit against.
  private func makeRunningFixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: "tg:dm:7",
        chatId: 7,
        userId: 7,
        text: "read a page",
        isEdited: false,
        ts: Date()
      )
    )
    let runs = RunStoreGRDB(writer: queue)
    let runId = claim.runId ?? 0
    _ = try #require(try runs.pickUp(runId: runId, now: Date()))
    return Fixture(queue: queue, runs: runs, sessionId: claim.sessionId ?? 0, runId: runId)
  }

  private func makeUsage(_ fixture: Fixture) -> ProviderUsage {
    makeProviderUsage(runId: fixture.runId, sessionId: fixture.sessionId)
  }

  private func makeExchange() -> ToolExchange {
    ToolExchange(
      assistantContent: "let me fetch that",
      toolCalls: [
        ToolCall(id: "c1", name: "web_fetch", argumentsJSON: #"{"url":"https://e.example/"}"#)
      ],
      observations: [
        ToolObservation(
          callId: "c1",
          toolName: "web_fetch",
          content: "raw page text",
          status: .ok,
          ingestedUntrusted: true
        )
      ]
    )
  }

  private func isTainted(_ fixture: Fixture) throws -> Bool {
    try fixture.queue.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT tainted FROM sessions WHERE id = ?",
        arguments: [fixture.sessionId]
      ) ?? false
    }
  }

  @Test func commitWritesExchangeRowsInOrderThenReplyThenTaint() throws {
    // given
    let fixture = try makeRunningFixture()
    let turn = AssistantTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      content: "summary of the page",
      usage: makeUsage(fixture),
      chunks: [
        OutboxChunk(stepIndex: 0, chatId: 7, payload: "summary of the page", payloadHash: "h")
      ],
      exchanges: [makeExchange()],
      setTainted: true
    )

    // when
    let result = try fixture.runs.commitAssistantTurn(turn, now: Date())

    // then
    #expect(result == .committed)
    let rows = try fixture.queue.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT id, role, content, provenance, tool_calls, tool_call_id, run_id FROM messages ORDER BY id ASC"
      )
    }
    // user inbound, exchange anchor, tool observation, final reply — count guards spurious rows
    #expect(rows.count == 4)
    let assistantRows = rows.filter { ($0["role"] as String?) == "assistant" }
    let toolRows = rows.filter { ($0["role"] as String?) == "tool" }
    #expect(assistantRows.count == 2)
    #expect(toolRows.count == 1)

    // the exchange anchor is the assistant row carrying the tool_calls
    let anchor = try #require(
      assistantRows.first { ($0["tool_calls"] as String?)?.contains("web_fetch") == true }
    )
    #expect(anchor["provenance"] == "trusted")
    #expect(anchor["run_id"] == fixture.runId)

    // the untrusted tool observation, raw and un-wrapped (§11)
    let toolRow = try #require(toolRows.first)
    #expect(toolRow["content"] == "raw page text")
    #expect(toolRow["provenance"] == "untrusted")
    #expect(toolRow["tool_call_id"] == "c1")
    #expect(toolRow["run_id"] == fixture.runId)

    // the final reply is the assistant row without tool_calls
    let reply = try #require(assistantRows.first { ($0["tool_calls"] as String?) == nil })
    #expect(reply["content"] == "summary of the page")
    #expect(reply["run_id"] == fixture.runId)

    // …InOrderThenReply: anchor → observation → reply by insertion id
    let anchorId = try #require(anchor["id"] as Int64?)
    let toolId = try #require(toolRow["id"] as Int64?)
    let replyId = try #require(reply["id"] as Int64?)
    #expect(anchorId < toolId)
    #expect(toolId < replyId)
    #expect(try isTainted(fixture))
  }

  @Test func committedTurnWithoutIngestionDoesNotTaint() throws {
    // given
    let fixture = try makeRunningFixture()
    let turn = AssistantTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      content: "plain",
      usage: makeUsage(fixture),
      chunks: [OutboxChunk(stepIndex: 0, chatId: 7, payload: "plain", payloadHash: "h")]
    )

    // when
    _ = try fixture.runs.commitAssistantTurn(turn, now: Date())

    // then
    #expect(try isTainted(fixture) == false)
  }

  @Test func degradedCommitStillTaints() throws {
    // given — spec §10: a degraded turn that ingested content persists the taint (amendment F)
    let fixture = try makeRunningFixture()
    let turn = DegradedTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      usage: makeUsage(fixture),
      chunk: OutboxChunk(stepIndex: 0, chatId: 7, payload: "degraded", payloadHash: "h"),
      setTainted: true
    )

    // when
    let result = try fixture.runs.commitDegradedTurn(turn, now: Date())

    // then — degraded path writes NO exchange rows, but the taint persists
    #expect(result == .committed)
    #expect(try isTainted(fixture))
    let toolRows = try fixture.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE role = 'tool'") ?? -1
    }
    #expect(toolRows == 0)
  }

  @Test func degradedCommitPersistsExecutedExchanges() throws {
    // given — a run that executed one exchange, then degraded: the work must survive
    let fixture = try makeRunningFixture()
    let turn = DegradedTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      usage: makeUsage(fixture),
      chunk: OutboxChunk(stepIndex: 0, chatId: 7, payload: "degraded", payloadHash: "h"),
      exchanges: [makeExchange()],
      setTainted: true
    )

    // when
    let result = try fixture.runs.commitDegradedTurn(turn, now: Date())

    // then — the same §11 row shapes as a completed turn: one trusted anchor with tool_calls,
    // one untrusted tool row carrying its call id
    #expect(result == .committed)
    let anchors = try fixture.queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages WHERE role = 'assistant' AND tool_calls IS NOT NULL"
      ) ?? -1
    }
    #expect(anchors == 1)
    let toolRows = try fixture.queue.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT provenance, tool_call_id FROM messages WHERE role = 'tool'"
      )
    }
    #expect(toolRows.count == 1)
    #expect(toolRows.first?["provenance"] == "untrusted")
    #expect(toolRows.first?["tool_call_id"] == "c1")
  }

  @Test func cancelledArbitrationArmStillTaints() throws {
    // given — /stop won the race (rev.1 M1: CANCELLED taints)
    let fixture = try makeRunningFixture()
    _ = try fixture.runs.cancelActiveRun(
      sessionId: fixture.sessionId,
      reason: .cancelled,
      now: Date()
    )
    let turn = AssistantTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      content: "late",
      usage: makeUsage(fixture),
      chunks: [OutboxChunk(stepIndex: 0, chatId: 7, payload: "late", payloadHash: "h")],
      exchanges: [makeExchange()],
      setTainted: true
    )

    // when
    let result = try fixture.runs.commitAssistantTurn(turn, now: Date())

    // then — usage recorded, no reply/exchange rows, taint SET
    #expect(result == .usageRecordedAfterTerminal)
    #expect(try isTainted(fixture))
    let messageCount = try fixture.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? -1
    }
    #expect(messageCount == 1)  // only the inbound user message
  }

  @Test func supersededArbitrationArmNeverRetaints() throws {
    // given — /new won the race; detaint already ran (rev.1 M1: SUPERSEDED skips)
    let fixture = try makeRunningFixture()
    _ = try fixture.runs.cancelActiveRun(
      sessionId: fixture.sessionId,
      reason: .superseded,
      now: Date()
    )
    let sessions = SessionMessageStoreGRDB(writer: fixture.queue)
    try sessions.resetWindowAndDetaint(sessionId: fixture.sessionId, now: Date())
    let turn = AssistantTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      content: "late",
      usage: makeUsage(fixture),
      chunks: [OutboxChunk(stepIndex: 0, chatId: 7, payload: "late", payloadHash: "h")],
      setTainted: true
    )

    // when
    let result = try fixture.runs.commitAssistantTurn(turn, now: Date())

    // then — the fresh window stays untainted
    #expect(result == .usageRecordedAfterTerminal)
    #expect(try isTainted(fixture) == false)
  }

  @Test func cancelledNilUsageDegradedCommitStillTaints() throws {
    // given — cancellation raced a degraded turn that has no usage row to record
    let fixture = try makeRunningFixture()
    _ = try fixture.runs.cancelActiveRun(
      sessionId: fixture.sessionId,
      reason: .cancelled,
      now: Date()
    )
    let turn = DegradedTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      chatId: 7,
      usage: nil,
      chunk: OutboxChunk(stepIndex: 0, chatId: 7, payload: "late", payloadHash: "h"),
      setTainted: true
    )

    // when
    let result = try fixture.runs.commitDegradedTurn(turn, now: Date())

    // then — nothing to record, but the ingestion happened: taint is a side effect of the
    // arbitration arm, not of usage recording
    #expect(result == .ignored)
    #expect(try isTainted(fixture))
  }
}
