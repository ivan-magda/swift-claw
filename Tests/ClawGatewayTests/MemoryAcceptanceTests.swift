// swiftlint:disable function_body_length
import ClawAgent
import ClawCore
import ClawData
import ClawWorkspace
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

/// Increment 3a acceptance gate (spec §14): the SC2 memory lifecycle plus the cross-cutting
/// integration seams — restart recall, delivered overflow notices, and the dormant ②/③ signals —
/// exercised over the real router → lane → TurnRunner → outbox stack.
@Suite struct MemoryAcceptanceTests {
  private func runStates(_ writer: any DatabaseWriter) throws -> [String] {
    try writer.read { db in
      try String.fetchAll(db, sql: "SELECT state FROM runs ORDER BY id ASC")
    }
  }

  private func waitForRunStates(
    _ writer: any DatabaseWriter,
    expected: [String]
  ) async throws {
    _ = try await pollUntil { try runStates(writer) == expected ? expected : nil }
    #expect(try runStates(writer) == expected)
  }

  private func auditActions(_ writer: any DatabaseWriter) throws -> [String] {
    try writer.read { db in
      try String.fetchAll(db, sql: "SELECT action FROM audit_events ORDER BY rowid")
    }
  }

  private func makeTempDatabasePath() -> String {
    NSTemporaryDirectory() + "claw-memory-accept-\(UInt64.random(in: 0..<(.max))).sqlite"
  }

  /// SC2 (spec §1.1, §14): tell it a fact today; it recalls it in a new conversation after a real
  /// restart; the owner reviews it with provenance and deletes it — and it stops being injected.
  @Test func sc2FactSurvivesRestartIsRecalledReviewedAndDeleted() async throws {
    // given — a file-backed database so the restart between phases is a real reopen
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let weekAgo = Date(timeIntervalSinceNow: -7 * 86_400)

    // when — phase 1 (first process): /remember → confirm prompt → owner replies yes
    do {
      let firstPool = try ClawDatabase.makePool(path: path)
      try ClawDatabase.migrate(firstPool)
      let firstStack = try makeStack(writer: firstPool, outcome: .respond("unused"))
      _ = await firstStack.router.handle(
        rawUpdate: textUpdate(id: 1, from: firstStack.chatId, text: "/remember project: ship 3a")
      )
      _ = await firstStack.router.handle(
        rawUpdate: textUpdate(id: 2, from: firstStack.chatId, text: "yes")
      )

      // then — the confirmed fact and its audit row are durable before the "process" exits
      let savedItems = try MemoryStoreGRDB(writer: firstPool).list(kind: .project, limit: 10)
      #expect(savedItems.count == 1)
      #expect(savedItems.first?.text == "ship 3a")
      #expect(savedItems.first?.source == .owner)
      #expect(try auditActions(firstPool).contains("memory_write"))
    }

    // when — phase 2 (restart): reopen the same file, back-date the fact a week, start a fresh
    // conversation, and run a real turn
    let pool = try ClawDatabase.makePool(path: path)
    try ClawDatabase.migrate(pool)
    let stack = try makeStack(writer: pool, outcome: .respond("stub answer"))
    // `try await`: in an async context Swift resolves to GRDB's async `write` overload; the bare
    // synchronous call does not compile (blind-review C1).
    try await pool.write { db in
      try db.execute(sql: "UPDATE memory_items SET created_at = ?", arguments: [weekAgo])
    }
    _ = await stack.router.handle(rawUpdate: textUpdate(id: 3, from: stack.chatId, text: "/new"))
    _ = await stack.router.handle(
      rawUpdate: textUpdate(id: 4, from: stack.chatId, text: "what are we working on?")
    )
    try await waitForRunStates(pool, expected: [RunState.done.rawValue])

    // then — the fact is injected as row 6b, untrusted-labeled, and never in the system role
    let turnRequest = try #require(await stack.provider.requests.first)
    let systemMessage = try #require(turnRequest.first)
    #expect(systemMessage.role == .system)
    #expect(systemMessage.content.contains("ship 3a") == false)
    let labeledMessage = try #require(
      turnRequest.first { message in
        message.role == .user && message.content.contains("label=\"memory_items\"")
      }
    )
    #expect(labeledMessage.content.contains("<claw-untrusted nonce="))
    #expect(labeledMessage.content.contains("ship 3a"))

    // when — phase 3: /memory review
    _ = await stack.router.handle(rawUpdate: textUpdate(id: 5, from: stack.chatId, text: "/memory"))

    // then — the listing shows id, kind group, source, and the back-dated day (provenance, FR-M6)
    let savedItem = try #require(
      try MemoryStoreGRDB(writer: pool).list(kind: .project, limit: 10).first
    )
    let reviewText = try #require(await stack.transport.sent.last?.text)
    #expect(reviewText.contains("project:"))
    #expect(reviewText.contains("\(savedItem.id) · «ship 3a» · owner"))
    let dayFormat = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
    #expect(reviewText.contains(weekAgo.formatted(dayFormat)))

    // when — phase 4: confirmed delete, then one more turn
    _ = await stack.router.handle(
      rawUpdate: textUpdate(id: 6, from: stack.chatId, text: "/memory delete \(savedItem.id)")
    )
    _ = await stack.router.handle(rawUpdate: textUpdate(id: 7, from: stack.chatId, text: "yes"))
    _ = await stack.router.handle(
      rawUpdate: textUpdate(id: 8, from: stack.chatId, text: "and now?")
    )
    try await waitForRunStates(pool, expected: [RunState.done.rawValue, RunState.done.rawValue])

    // then — hard-deleted, audited, and no longer injected into the next turn's context
    #expect(try MemoryStoreGRDB(writer: pool).get(id: savedItem.id) == nil)
    #expect(try auditActions(pool).contains("memory_delete"))
    let finalRequest = try #require(await stack.provider.requests.last)
    #expect(
      finalRequest.allSatisfy { message in message.content.contains("ship 3a") == false }
    )
  }

  /// R2 (spec §10.2): a plain message from before a restart is found via FTS5/BM25 in a fresh
  /// conversation window and injected as an untrusted-labeled recall row — not as history.
  @Test func factMentionedBeforeRestartIsRecalledAfterNewConversation() async throws {
    // given — a file-backed database so the FTS index must survive a real reopen
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    // when — first process: a normal turn mentions the fact, then the process "exits"
    do {
      let firstPool = try ClawDatabase.makePool(path: path)
      try ClawDatabase.migrate(firstPool)
      let firstStack = try makeStack(writer: firstPool, outcome: .respond("noted"))
      _ = await firstStack.router.handle(
        rawUpdate: textUpdate(id: 1, from: firstStack.chatId, text: "the wifi password is hunter2")
      )
      try await waitForRunStates(firstPool, expected: [RunState.done.rawValue])
    }

    // when — restart: /new opens a fresh conversation window, then the owner asks again
    let pool = try ClawDatabase.makePool(path: path)
    try ClawDatabase.migrate(pool)
    let stack = try makeStack(writer: pool, outcome: .respond("stub answer"))
    _ = await stack.router.handle(rawUpdate: textUpdate(id: 2, from: stack.chatId, text: "/new"))
    _ = await stack.router.handle(
      rawUpdate: textUpdate(id: 3, from: stack.chatId, text: "what is the wifi password?")
    )
    try await waitForRunStates(pool, expected: [RunState.done.rawValue, RunState.done.rawValue])

    // then — the pre-restart message reaches the model ONLY inside the labeled recall row
    let turnRequest = try #require(await stack.provider.requests.first)
    let labeledMessage = try #require(
      turnRequest.first { message in
        message.role == .user && message.content.contains("label=\"recall\"")
      }
    )
    #expect(labeledMessage.content.contains("the wifi password is hunter2"))
    let messagesWithFact = turnRequest.filter { message in message.content.contains("hunter2") }
    #expect(messagesWithFact == [labeledMessage])
  }

  /// H2 (spec §6.1, §14): an over-cap MEMORY.md is omitted from the model context AND the owner
  /// receives the consolidation notice through the real outbox delivery path — and recovery
  /// commands keep working while the file is over cap.
  @Test func overCapMemoryFileIsOmittedAndTheConsolidationNoticeIsDelivered() async throws {
    // given — a real on-disk workspace whose MEMORY.md exceeds the 2200-grapheme hard cap
    let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("claw-workspace-\(UInt64.random(in: 0..<(.max)))", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspaceRoot) }
    let overCapBody = String(repeating: "OVERFLOW-CANARY ", count: 138)  // 2208 graphemes > 2200
    try overCapBody.write(
      to: workspaceRoot.appendingPathComponent("MEMORY.md"),
      atomically: true,
      encoding: .utf8
    )

    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStack(
      writer: queue,
      outcome: .respond("stub answer"),
      workspace: FileSystemWorkspace(root: workspaceRoot)
    )

    // when — a normal turn commits, then the dispatcher drains the outbox
    _ = await stack.router.handle(rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "hello"))
    try await waitForRunStates(queue, expected: [RunState.done.rawValue])
    await stack.dispatcher.drainOnce()

    // then — the file never reached the model, and the owner received notice + reply together
    let turnRequest = try #require(await stack.provider.requests.first)
    #expect(
      turnRequest.allSatisfy { message in message.content.contains("OVERFLOW-CANARY") == false }
    )
    let delivered = try #require(await stack.transport.richSends.first?.markdown)
    #expect(delivered.contains("`MEMORY.md` is 2208/2200"))
    #expect(delivered.contains("stub answer"))

    // when — the owner runs a recovery command while the file is still over cap
    _ = await stack.router.handle(rawUpdate: textUpdate(id: 2, from: stack.chatId, text: "/memory"))

    // then — command handling is independent of context assembly (spec §6.1)
    #expect(await stack.transport.sent.last?.text == MemoryReplies.emptyReview(kind: nil))
  }

  /// ③ (spec §2, §7.5): the taint-read guard is wired but dormant. Untainted turns inject
  /// high-sensitivity items; once `sessions.tainted` is set (3b's job — forced here via SQL),
  /// the real snapshot → fetchRanked seam excludes them.
  @Test func taintReadGuardExcludesHighSensitivityItemsThroughTheRealStores() async throws {
    // given — one normal and one high-sensitivity fact in the real GRDB store
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStack(writer: queue, outcome: .respond("stub answer"))
    let memoryStore = MemoryStoreGRDB(writer: queue)
    _ = try memoryStore.append(
      NewMemoryItem(text: "normal fact", kind: .user, sessionId: nil),
      now: Date(timeIntervalSince1970: 86_400)
    )
    _ = try memoryStore.append(
      NewMemoryItem(text: "secret omega", kind: .user, sensitivity: .high, sessionId: nil),
      now: Date(timeIntervalSince1970: 172_800)
    )

    // when — an untainted turn runs
    _ = await stack.router.handle(rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "hi"))
    try await waitForRunStates(queue, expected: [RunState.done.rawValue])

    // then — the guard is dormant: both items inject while the session is untainted
    let untaintedRequest = try #require(await stack.provider.requests.first)
    let untaintedLabeled = try #require(
      untaintedRequest.first { message in message.content.contains("label=\"memory_items\"") }
    )
    #expect(untaintedLabeled.content.contains("normal fact"))
    #expect(untaintedLabeled.content.contains("secret omega"))

    // when — the session is marked tainted (3a only READS this flag; 3b sets it)
    let sessionId = try stack.sessionMessages.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: stack.chatId),
      now: Date()
    )
    try await queue.write { db in
      try db.execute(sql: "UPDATE sessions SET tainted = 1 WHERE id = ?", arguments: [sessionId])
    }
    _ = await stack.router.handle(rawUpdate: textUpdate(id: 2, from: stack.chatId, text: "again"))
    try await waitForRunStates(queue, expected: [RunState.done.rawValue, RunState.done.rawValue])

    // then — the tainted read excludes the high-sensitivity item and keeps the normal one
    let taintedRequest = try #require(await stack.provider.requests.last)
    let taintedLabeled = try #require(
      taintedRequest.first { message in message.content.contains("label=\"memory_items\"") }
    )
    #expect(taintedLabeled.content.contains("normal fact"))
    #expect(taintedLabeled.content.contains("secret omega") == false)
  }

  /// ② (spec §7.5): `hasPrivateDataAccess` over the REAL GRDB store — false with nothing durable,
  /// true the moment any memory_item is injected, false again after it is deleted.
  @Test func hasPrivateDataAccessTracksMemoryInjectionOverTheRealStores() throws {
    // given — a builder over the real stores and an empty workspace
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let memoryStore = MemoryStoreGRDB(writer: queue)
    let builder = makeAcceptanceContextBuilder(writer: queue)
    let snapshot = SessionContextSnapshot(
      history: [StoredMessage(role: .user, content: "hello", provenance: .trusted)],
      historyMessageIds: [1],
      windowStartMessageId: 0,
      isTainted: false
    )

    // when — nothing private exists yet
    let emptyResult = try builder.assemble(snapshot: snapshot, sessionId: 1)

    // then
    #expect(emptyResult.hasPrivateDataAccess == false)

    // when — one durable fact is appended
    let appended = try memoryStore.append(
      NewMemoryItem(text: "durable fact", kind: .user, sessionId: nil),
      now: Date(timeIntervalSince1970: 86_400)
    )
    let injectedResult = try builder.assemble(snapshot: snapshot, sessionId: 1)

    // then
    #expect(injectedResult.hasPrivateDataAccess)
    #expect(
      injectedResult.messages.contains { message in message.content.contains("durable fact") }
    )

    // when — the fact is deleted again
    #expect(try memoryStore.delete(id: appended.id))
    let deletedResult = try builder.assemble(snapshot: snapshot, sessionId: 1)

    // then
    #expect(deletedResult.hasPrivateDataAccess == false)
  }
}
// swiftlint:enable function_body_length
