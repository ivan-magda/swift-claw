import ClawAgent
import ClawCore
import ClawData
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

/// The inbound → run bridge mints the session key from the resolved mode, so a topic's turns land
/// in that topic's own session and a DM's key is byte-identical to what it has always been.
@Suite struct TurnDispatchModeTests {
  private struct Harness {
    let dispatch: TurnDispatch
    let sessionMessages: SessionMessageStoreGRDB
    let runner: FakeTurnRunner

    func storedContent(chatId: Int64, threadId: Int64) throws -> [String] {
      try storedContent(sessionKey: SessionKey.telegramTopic(chatId: chatId, threadId: threadId))
    }

    func storedContent(sessionKey: String) throws -> [String] {
      guard let sessionId = try sessionMessages.findSession(sessionKey: sessionKey) else {
        return []
      }
      return try sessionMessages.loadContextSnapshot(
        sessionId: sessionId,
        throughMessageId: Int64.max,
        limit: 10
      ).history.map(\.content)
    }
  }

  private func makeHarness() throws -> Harness {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let runner = FakeTurnRunner()
    let logger = TestLog.silent

    let dispatch = TurnDispatch(
      sessionMessages: sessionMessages,
      enqueuer: TurnEnqueuer(lanes: SessionLaneRegistry(), turns: runner, logger: logger),
      replies: ReplySender(
        processed: ProcessedUpdateStoreGRDB(writer: queue),
        delivery: RecordingTransport(),
        logger: logger
      ),
      imageCache: ImageCache(),
      now: { Date(timeIntervalSince1970: 100) },
      logger: logger
    )

    return Harness(dispatch: dispatch, sessionMessages: sessionMessages, runner: runner)
  }

  private func update(
    id: Int64,
    chatId: Int64,
    threadId: Int64?,
    displayName: String? = nil
  ) throws -> (RawUpdate, IncomingMessage) {
    let raw = RawUpdate(
      updateId: id,
      message: RawMessage(
        messageId: id,
        fromUserId: 500,
        chatId: chatId,
        text: "hello",
        caption: nil,
        mediaKind: nil,
        chatKind: threadId == nil ? .private : .supergroup,
        messageThreadId: threadId,
        senderDisplayName: displayName
      ),
      editedMessage: nil
    )
    return (raw, try #require(IncomingMessage.normalize(from: raw)))
  }

  @Test func aGroupDispatchPersistsUnderTheTopicKey() async throws {
    // given
    let harness = try makeHarness()
    let (raw, message) = try update(id: 1, chatId: -1_001_234, threadId: 9)

    // when
    let outcome = try await harness.dispatch.dispatch(
      rawUpdate: raw,
      message: message,
      text: "hello",
      mode: .group
    )

    // then
    #expect(outcome == .processed)
    let sessionId = try #require(
      try harness.sessionMessages.findSession(
        sessionKey: SessionKey.telegramTopic(chatId: -1_001_234, threadId: 9)
      )
    )
    #expect(try harness.sessionMessages.findSession(sessionKey: "tg:dm:-1001234") == nil)
    let snapshot = try harness.sessionMessages.loadContextSnapshot(
      sessionId: sessionId,
      throughMessageId: Int64.max,
      limit: 10
    )
    #expect(SessionKey.mode(from: snapshot.sessionKey) == .group)
    #expect(SessionKey.threadId(from: snapshot.sessionKey) == 9)
  }

  @Test func twoTopicsOfOneChatNeverShareASession() async throws {
    // given
    let harness = try makeHarness()
    let (firstRaw, firstMessage) = try update(id: 1, chatId: -1_001_234, threadId: 9)
    let (secondRaw, secondMessage) = try update(id: 2, chatId: -1_001_234, threadId: 10)

    // when
    _ = try await harness.dispatch.dispatch(
      rawUpdate: firstRaw,
      message: firstMessage,
      text: "in nine",
      mode: .group
    )
    _ = try await harness.dispatch.dispatch(
      rawUpdate: secondRaw,
      message: secondMessage,
      text: "in ten",
      mode: .group
    )

    // then
    await harness.runner.waitForCalls(atLeast: 2)
    let calls = await harness.runner.calls
    #expect(Set(calls.map(\.sessionId)).count == 2)
  }

  @Test func aDirectDispatchStillUsesTheDMKeyEvenWhenTheMessageCarriesATopic() async throws {
    // given — the mode, not the wire, decides; a topic on a DM-mode message must not leak in
    let harness = try makeHarness()
    let (raw, message) = try update(id: 1, chatId: 42, threadId: 9)

    // when
    _ = try await harness.dispatch.dispatch(rawUpdate: raw, message: message, text: "hello")

    // then
    #expect(try harness.sessionMessages.findSession(sessionKey: "tg:dm:42") != nil)
  }

  @Test func aGroupTurnStoresTheSpeakerWithTheLine() async throws {
    // given
    let harness = try makeHarness()
    let (raw, message) = try update(
      id: 1,
      chatId: -1_001_234,
      threadId: 9,
      displayName: "Ada Lovelace"
    )

    // when
    _ = try await harness.dispatch.dispatch(
      rawUpdate: raw,
      message: message,
      text: "hello",
      mode: .group
    )

    // then — the author rides in the stored content, so recall carries it too
    #expect(try harness.storedContent(chatId: -1_001_234, threadId: 9) == ["Ada Lovelace: hello"])
  }

  @Test func anObservedGroupLineStoresItsSpeakerToo() async throws {
    // given — the bot was not addressed, so the room's transcript is all this write produces
    let harness = try makeHarness()
    let (raw, message) = try update(
      id: 1,
      chatId: -1_001_234,
      threadId: 9,
      displayName: "Ada Lovelace"
    )

    // when
    let outcome = await harness.dispatch.observe(
      rawUpdate: raw,
      message: message,
      text: "hello",
      mode: .group
    )

    // then
    #expect(outcome == .processed)
    #expect(try harness.storedContent(chatId: -1_001_234, threadId: 9) == ["Ada Lovelace: hello"])
  }

  @Test func aGroupSpeakerWithNoDisplayNameIsStoredByUserId() async throws {
    // given
    let harness = try makeHarness()
    let (raw, message) = try update(id: 1, chatId: -1_001_234, threadId: 9)

    // when
    _ = try await harness.dispatch.dispatch(
      rawUpdate: raw,
      message: message,
      text: "hello",
      mode: .group
    )

    // then
    #expect(try harness.storedContent(chatId: -1_001_234, threadId: 9) == ["user 500: hello"])
  }

  @Test func aDirectTurnStoresTheTextUnprefixed() async throws {
    // given
    let harness = try makeHarness()
    let (raw, message) = try update(id: 1, chatId: 42, threadId: nil, displayName: "Ada Lovelace")

    // when
    _ = try await harness.dispatch.dispatch(rawUpdate: raw, message: message, text: "hello")

    // then
    #expect(try harness.storedContent(sessionKey: "tg:dm:42") == ["hello"])
  }
}
