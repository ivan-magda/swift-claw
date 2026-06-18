import ClawCore
import ClawData
import Logging
import Testing

@testable import ClawGateway

@Suite struct MessageRouterTests {
  private func makeRouter(allowed: [Int64]) throws -> (MessageRouter, RecordingTransport) {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)

    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: allowed)

    let transport = RecordingTransport()
    let router = MessageRouter(
      updateStore: ProcessedUpdateStoreGRDB(writer: queue),
      accessControl: AccessControl(allowlist: allowlist),
      transport: transport,
      logger: Logger(label: "test")
    )

    return (router, transport)
  }

  @Test func allowlistedTextIsEchoed() async throws {
    // given
    let (router, transport) = try makeRouter(allowed: [42])

    // when
    await router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "hello"))

    // then
    let sent = await transport.sent
    #expect(sent.count == 1)
    #expect(sent[0].chatId == 42)
    #expect(sent[0].text == "You said: hello")
  }

  @Test func unknownSenderGetsPrivateBotReply() async throws {
    // given
    let (router, transport) = try makeRouter(allowed: [42])

    // when
    await router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "let me in"))

    // then
    let sent = await transport.sent
    #expect(sent.count == 1)
    #expect(sent[0].text == "Sorry — this is a private bot.")
  }

  @Test func unknownSenderStartEchoesTheirOwnId() async throws {
    // given
    let (router, transport) = try makeRouter(allowed: [42])

    // when
    await router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "/start"))

    // then
    let sent = await transport.sent
    #expect(sent.count == 1)
    #expect(sent[0].text.contains("7"))  // echoes THEIR id
    #expect(sent[0].text.contains("private bot"))
    #expect(sent[0].text.contains("42") == false)  // never reveals the allowlist
  }

  @Test func allowlistedStartGetsWelcome() async throws {
    // given
    let (router, transport) = try makeRouter(allowed: [42])

    // when
    await router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "/start"))

    // then
    let sent = await transport.sent
    #expect(sent[0].text.contains("private bot") == false)
  }

  @Test func unsupportedMediaGetsFriendlyReply() async throws {
    // given
    let (router, transport) = try makeRouter(allowed: [42])
    let raw = RawUpdate(
      updateId: 1,
      message: RawMessage(
        messageId: 1,
        fromUserId: 42,
        chatId: 42,
        text: nil,
        caption: nil,
        mediaKind: "photos"
      ),
      editedMessage: nil
    )

    // when
    await router.handle(rawUpdate: raw)

    // then
    let sent = await transport.sent
    #expect(sent[0].text == "I can't read photos yet.")
  }

  @Test func duplicateUpdateIsNotProcessedTwice() async throws {
    // given
    let (router, transport) = try makeRouter(allowed: [42])

    // when
    await router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "hi"))
    await router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "hi"))  // same update_id

    // then
    let sent = await transport.sent
    #expect(sent.count == 1)  // dedup: only one echo
  }
}
