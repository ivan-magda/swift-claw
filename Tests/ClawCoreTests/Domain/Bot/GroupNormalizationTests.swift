import Testing

@testable import ClawCore

@Suite struct GroupNormalizationTests {
  private func groupMessage(
    messageId: Int64 = 500,
    threadId: Int64? = 77,
    hasSenderChat: Bool = false
  ) -> RawMessage {
    RawMessage(
      messageId: messageId,
      fromUserId: 42,
      chatId: -1_001_234,
      text: "@claw_bot ping",
      caption: nil,
      mediaKind: nil,
      chatKind: .supergroup,
      messageThreadId: threadId,
      replyToMessageId: 499,
      replyToUserId: 7,
      senderDisplayName: "Ada Lovelace",
      hasSenderChat: hasSenderChat,
      migratedToChatId: -1_009_999
    )
  }

  @Test func everyGroupFieldSurvivesNormalization() throws {
    // given
    let raw = RawUpdate(updateId: 20, message: groupMessage(), editedMessage: nil)

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.chatKind == .supergroup)
    #expect(incoming.messageThreadId == 77)
    #expect(incoming.replyToMessageId == 499)
    #expect(incoming.replyToUserId == 7)
    #expect(incoming.senderDisplayName == "Ada Lovelace")
    #expect(incoming.migratedToChatId == -1_009_999)
  }

  @Test func generalTopicStaysDistinctFromTheFirstTopic() throws {
    // given — the General topic omits the thread id; topic 1 is a real, separate topic
    let general = RawUpdate(
      updateId: 21,
      message: groupMessage(messageId: 501, threadId: nil),
      editedMessage: nil
    )
    let firstTopic = RawUpdate(
      updateId: 22,
      message: groupMessage(messageId: 502, threadId: 1),
      editedMessage: nil
    )

    // when
    let generalMessage = try #require(IncomingMessage.normalize(from: general))
    let topicMessage = try #require(IncomingMessage.normalize(from: firstTopic))

    // then
    #expect(generalMessage.messageThreadId == nil)
    #expect(topicMessage.messageThreadId == 1)
  }

  @Test func messageSentOnBehalfOfAChatIsDropped() {
    // given — an anonymous admin or channel post: the sender id identifies no human we can allow
    let raw = RawUpdate(
      updateId: 23,
      message: groupMessage(hasSenderChat: true),
      editedMessage: nil
    )

    // when
    let incoming = IncomingMessage.normalize(from: raw)

    // then
    #expect(incoming == nil)
  }

  @Test func directMessageKeepsThePrivateDefaults() throws {
    // given — the shape every pre-group-mode caller builds
    let raw = RawUpdate(
      updateId: 24,
      message: RawMessage(
        messageId: 10,
        fromUserId: 42,
        chatId: 42,
        text: "hi",
        caption: nil,
        mediaKind: nil
      ),
      editedMessage: nil
    )

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.chatKind == .private)
    #expect(incoming.messageThreadId == nil)
    #expect(incoming.replyToMessageId == nil)
    #expect(incoming.replyToUserId == nil)
    #expect(incoming.senderDisplayName == nil)
    #expect(incoming.migratedToChatId == nil)
  }
}
