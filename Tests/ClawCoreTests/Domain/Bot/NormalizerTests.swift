import Testing

@testable import ClawCore

@Suite
struct NormalizerTests {
  private func msg(
    messageID: Int64 = 10,
    from: Int64? = 42,
    chat: Int64 = 42,
    text: String? = nil,
    caption: String? = nil,
    media: String? = nil,
    voice: VoiceAttachment? = nil,
    photo: PhotoAttachment? = nil
  ) -> RawMessage {
    RawMessage(
      messageID: messageID,
      fromUserID: from,
      chatID: chat,
      text: text,
      caption: caption,
      mediaKind: media,
      voice: voice,
      photo: photo
    )
  }

  private let voiceNote = VoiceAttachment(
    fileID: "voice-file-1",
    durationSeconds: 8,
    mimeType: "audio/ogg",
    fileSizeBytes: 31_942
  )

  private let rainbow = PhotoAttachment(sizes: [
    PhotoSize(
      fileID: "y-id",
      fileUniqueID: "y-u",
      width: 1280,
      height: 960,
      fileSizeBytes: 186_422
    ),
  ])

  @Test
  func plainTextMessageNormalizes() throws {
    // given
    let raw = RawUpdate(updateID: 1, message: msg(text: "hi"), editedMessage: nil)

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.updateID == 1)
    #expect(incoming.userID == 42)
    #expect(incoming.chatID == 42)
    #expect(incoming.content == .text("hi"))
    #expect(incoming.isEdited == false)
  }

  @Test
  func captionOnMediaWithoutAnAttachmentIsTreatedAsText() throws {
    // given — media presence with nothing fetchable behind it
    let raw = RawUpdate(
      updateID: 2,
      message: msg(caption: "look", media: "photos", photo: nil),
      editedMessage: nil
    )

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.content == .text("look"))
  }

  @Test
  func mediaWithoutCaptionIsUnsupported() throws {
    // given
    let raw = RawUpdate(updateID: 3, message: msg(media: "voice messages"), editedMessage: nil)

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.content == .unsupported(kind: "voice messages"))
  }

  @Test
  func bareVoiceNoteNormalizesToVoiceContent() throws {
    // given — the real Telegram client shape: a voice attachment, no text, no caption
    let raw = RawUpdate(
      updateID: 4,
      message: msg(media: VoiceAttachment.mediaKindDescription, voice: voiceNote),
      editedMessage: nil
    )

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.content == .voice(voiceNote))
  }

  @Test
  func captionedVoiceStaysATextMessage() throws {
    // given — written text always outranks the attachment
    let raw = RawUpdate(
      updateID: 5,
      message: msg(
        caption: "listen to this",
        media: VoiceAttachment.mediaKindDescription,
        voice: voiceNote
      ),
      editedMessage: nil
    )

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.content == .text("listen to this"))
  }

  @Test
  func captionedPhotoKeepsTheImage() throws {
    // given — the flow that used to answer "I don't see an attached image"
    let raw = RawUpdate(
      updateID: 20,
      message: msg(caption: "Что это?", media: "photos", photo: rainbow),
      editedMessage: nil
    )

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then — the caption travels WITH the image rather than replacing it
    #expect(incoming.content == .photo(rainbow, caption: "Что это?"))
  }

  @Test
  func barePhotoNormalizesToPhotoContent() throws {
    // given
    let raw = RawUpdate(
      updateID: 21,
      message: msg(media: "photos", photo: rainbow),
      editedMessage: nil
    )

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.content == .photo(rainbow, caption: nil))
  }

  @Test
  func photoWithNoUsableRungFallsBackToUnsupported() throws {
    // given — the wire dropped every malformed rung, leaving presence only
    let raw = RawUpdate(updateID: 22, message: msg(media: "photos", photo: nil), editedMessage: nil)

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.content == .unsupported(kind: "photos"))
  }

  @Test
  func editedMessageIsFlagged() throws {
    // given
    let raw = RawUpdate(updateID: 4, message: nil, editedMessage: msg(text: "fixed"))

    // when
    let incoming = try #require(IncomingMessage.normalize(from: raw))

    // then
    #expect(incoming.content == .text("fixed"))
    #expect(incoming.isEdited == true)
  }

  @Test
  func missingSenderIsIgnored() {
    // given
    let raw = RawUpdate(updateID: 5, message: msg(from: nil, text: "hi"), editedMessage: nil)

    // then
    #expect(IncomingMessage.normalize(from: raw) == nil)
  }

  @Test
  func emptyUpdateIsIgnored() {
    // given
    let raw = RawUpdate(updateID: 6, message: nil, editedMessage: nil)

    // then
    #expect(IncomingMessage.normalize(from: raw) == nil)
  }
}
