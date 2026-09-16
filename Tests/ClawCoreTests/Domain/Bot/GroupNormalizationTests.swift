import Testing

@testable import ClawCore

@Suite
struct GroupNormalizationTests {
  private func groupMessage(
    messageID: Int64 = 500,
    threadID: Int64? = 77,
    hasSenderChat: Bool = false
  ) -> RawMessage {
    RawMessage(
      messageID: messageID,
      fromUserID: 42,
      chatID: -1_001_234,
      text: "@claw_bot ping",
      caption: nil,
      mediaKind: nil,
      chatKind: .supergroup,
      messageThreadID: threadID,
      replyToMessageID: 499,
      replyToUserID: 7,
      senderDisplayName: "Ada Lovelace",
      hasSenderChat: hasSenderChat,
      migratedToChatID: -1_009_999
    )
  }

  @Test
  func everyGroupFieldSurvivesNormalization() throws {
    // given
    let raw = RawUpdate(updateID: 20, message: groupMessage(), editedMessage: nil)

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.chatKind == .supergroup)
    #expect(incoming.messageThreadID == 77)
    #expect(incoming.replyToMessageID == 499)
    #expect(incoming.replyToUserID == 7)
    #expect(incoming.senderDisplayName == "Ada Lovelace")
    #expect(incoming.migratedToChatID == -1_009_999)
  }

  @Test
  func generalTopicStaysDistinctFromTheFirstTopic() throws {
    // given — the General topic omits the thread id; topic 1 is a real, separate topic
    let general = RawUpdate(
      updateID: 21,
      message: groupMessage(messageID: 501, threadID: nil),
      editedMessage: nil
    )
    let firstTopic = RawUpdate(
      updateID: 22,
      message: groupMessage(messageID: 502, threadID: 1),
      editedMessage: nil
    )

    // when
    let generalMessage = try #require(IncomingMessage.normalize(from: general))
    let topicMessage = try #require(IncomingMessage.normalize(from: firstTopic))

    // then
    #expect(generalMessage.messageThreadID == nil)
    #expect(topicMessage.messageThreadID == 1)
  }

  @Test
  func messageSentOnBehalfOfAChatIsDropped() {
    // given — an anonymous admin or channel post: the sender id identifies no human we can allow
    let raw = RawUpdate(
      updateID: 23,
      message: groupMessage(hasSenderChat: true),
      editedMessage: nil
    )

    // when
    let incoming = IncomingMessage.normalize(from: raw)

    // then
    #expect(incoming == nil)
  }

  @Test
  func directMessageKeepsThePrivateDefaults() throws {
    // given — the shape every pre-group-mode caller builds
    let raw = RawUpdate(
      updateID: 24,
      message: RawMessage(
        messageID: 10,
        fromUserID: 42,
        chatID: 42,
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
    #expect(incoming.messageThreadID == nil)
    #expect(incoming.replyToMessageID == nil)
    #expect(incoming.replyToUserID == nil)
    #expect(incoming.senderDisplayName == nil)
    #expect(incoming.migratedToChatID == nil)
  }
}
