import ClawCore
import ClawData
import Foundation
import Logging
import Testing

@testable import ClawGateway

@Suite struct AcceptanceTests {
  // Echo an allowlisted DM; refuse an unknown sender (default-deny) with an onboarding self-ID
  // that never leaks the allowlist; reply to unsupported media with a friendly note.
  @Test func echoRefuseOnboardAndNonText() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [42])
    let photo = RawUpdate(
      updateId: 3,
      message: RawMessage(
        messageId: 3,
        fromUserId: 42,
        chatId: 42,
        text: nil,
        caption: nil,
        mediaKind: "photos"
      ),
      editedMessage: nil
    )
    let transport = RecordingTransport(batches: [
      [
        textUpdate(id: 1, from: 42, text: "hi"),  // allowlisted → echo
        textUpdate(id: 2, from: 7, text: "/start"),  // unknown → onboarding self-ID
        photo,  // allowlisted non-text → friendly reply
      ]
    ])
    let daemon = Daemon(
      transport: transport,
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      allowlist: allowlist,
      cursor: UpdateCursorStoreGRDB(writer: queue),
      pollTimeout: 0,
      logger: Logger(label: "accept"),
      gracefulShutdownSignals: []  // no process-wide signal trap in tests
    )

    // when
    let task = Task { try await daemon.run() }
    try await waitUntil { await transport.sentCount >= 3 }
    task.cancel()
    try await task.value

    // then
    let sent = await transport.sent
    #expect(sent.contains { $0.chatId == 42 && $0.text == "You said: hi" })  // echo
    #expect(
      sent.contains { $0.chatId == 7 && $0.text.contains("7") && $0.text.contains("private bot") }
    )  // onboarding
    #expect(sent.contains { $0.chatId == 7 && $0.text.contains("42") } == false)  // never leaks allowlist
    #expect(sent.contains { $0.text == "I can't read photos yet." })  // non-text
  }

  // Survives restart: the offset persists and a redelivered update is deduped.
  @Test func offsetPersistsAndDedupsAcrossRestart() async throws {
    // given
    let path = NSTemporaryDirectory() + "claw-accept-\(UInt64.random(in: 0..<(.max))).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }

    // when — first "run": process update 100, advance the cursor
    do {
      let stores = try ClawDatabase.openStores(path: path)
      try stores.allowlist.seedAllowlist(userIds: [42])
      #expect(try stores.processed.claimUpdate(updateId: 100))  // newly claimed
      try stores.cursor.advanceCursor(to: 100)
    }

    // then — "restart": fresh stores on the same file
    let reopened = try ClawDatabase.openStores(path: path)
    #expect(try reopened.cursor.loadCursor() == 100)  // offset survived
    #expect(try reopened.processed.claimUpdate(updateId: 100) == false)  // redelivery deduped
  }
}
