import ClawAgent
import ClawCore
import ClawData
import Foundation
import GRDB
import Logging

@testable import ClawGateway

/// Shared fixture for the Plan 6 routing suites: a migrated in-memory database and a router wired
/// with real GRDB memory stores, a recording transport, and a fake turn dispatcher.
struct MemoryRoutingHarness {
  let router: MessageRouter

  let transport: RecordingTransport
  let dispatcher: FakeTurnRunner

  let sessionMessages: SessionMessageStoreGRDB
  let memory: MemoryStoreGRDB

  let pendingConfirmations: PendingConfirmationRegistry
  let queue: DatabaseQueue

  static func make(
    allowed: [Int64] = [42],
    memoryCommands: (any MemoryCommandStore)? = nil,
    routerSessionMessages: ((SessionMessageStoreGRDB) -> any SessionMessageStore)? = nil
  ) throws -> MemoryRoutingHarness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)

    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: allowed)

    let transport = RecordingTransport()
    let dispatcher = FakeTurnRunner()
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let memory = MemoryStoreGRDB(writer: queue)
    let pendingConfirmations = PendingConfirmationRegistry()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: routerSessionMessages?(sessionMessages) ?? sessionMessages,
      commands: CommandStoreGRDB(writer: queue),
      memory: memory,
      memoryCommands: memoryCommands ?? MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: pendingConfirmations,
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      delivery: transport,
      turnRunner: dispatcher,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      logger: TestLog.silent
    )

    return MemoryRoutingHarness(
      router: router,
      transport: transport,
      dispatcher: dispatcher,
      sessionMessages: sessionMessages,
      memory: memory,
      pendingConfirmations: pendingConfirmations,
      queue: queue
    )
  }

  func ownerSessionId() throws -> Int64 {
    try sessionMessages.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      now: Date(timeIntervalSince1970: 0)
    )
  }

  func seedItem(text: String, kind: MemoryKind, day: Double = 86_400) throws -> MemoryItem {
    try memory.append(
      NewMemoryItem(text: text, kind: kind, sessionId: nil),
      now: Date(timeIntervalSince1970: day)
    )
  }

  func memoryItemCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items") ?? 0
    }
  }

  func auditActions() throws -> [String] {
    try queue.read { db in
      try String.fetchAll(db, sql: "SELECT action FROM audit_events ORDER BY rowid")
    }
  }

  func messageCount(content: String) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages WHERE content = ?",
        arguments: [content]
      ) ?? 0
    }
  }
}
