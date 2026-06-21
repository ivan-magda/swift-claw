import Testing

@testable import ClawCore

@Suite struct NormalizerTests {
  private func msg(
    messageId: Int64 = 10,
    from: Int64? = 42,
    chat: Int64 = 42,
    text: String? = nil,
    caption: String? = nil,
    media: String? = nil
  ) -> RawMessage {
    RawMessage(
      messageId: messageId,
      fromUserId: from,
      chatId: chat,
      text: text,
      caption: caption,
      mediaKind: media
    )
  }

  @Test func plainTextMessageNormalizes() throws {
    // given
    let raw = RawUpdate(updateId: 1, message: msg(text: "hi"), editedMessage: nil)

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.updateId == 1)
    #expect(incoming.userId == 42)
    #expect(incoming.chatId == 42)
    #expect(incoming.content == .text("hi"))
    #expect(incoming.isEdited == false)
  }

  @Test func captionIsTreatedAsText() throws {
    // given
    let raw = RawUpdate(
      updateId: 2,
      message: msg(caption: "look", media: "photos"),
      editedMessage: nil
    )

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.content == .text("look"))
  }

  @Test func mediaWithoutCaptionIsUnsupported() throws {
    // given
    let raw = RawUpdate(updateId: 3, message: msg(media: "voice messages"), editedMessage: nil)

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.content == .unsupported(kind: "voice messages"))
  }

  @Test func editedMessageIsFlagged() throws {
    // given
    let raw = RawUpdate(updateId: 4, message: nil, editedMessage: msg(text: "fixed"))

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.content == .text("fixed"))
    #expect(incoming.isEdited == true)
  }

  @Test func missingSenderIsIgnored() {
    // given
    let raw = RawUpdate(updateId: 5, message: msg(from: nil, text: "hi"), editedMessage: nil)

    // then
    #expect(IncomingMessage.normalize(from: raw) == nil)
  }

  @Test func emptyUpdateIsIgnored() {
    // given
    let raw = RawUpdate(updateId: 6, message: nil, editedMessage: nil)

    // then
    #expect(IncomingMessage.normalize(from: raw) == nil)
  }
}
