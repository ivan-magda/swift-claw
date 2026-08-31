import ClawCore
import Testing

@testable import ClawGateway

@Suite struct AddressingResolverTests {
  private let identity = BotIdentity(id: 900, username: "claw_bot")

  private func resolver(identity: BotIdentity?) -> AddressingResolver {
    AddressingResolver(identity: identity)
  }

  private func groupMessage(
    text: String? = nil,
    caption: String? = nil,
    photo: Bool = false,
    voice: Bool = false,
    unsupported: String? = nil,
    replyToUserId: Int64? = nil
  ) -> IncomingMessage {
    let content: IncomingMessage.Content
    if photo {
      content = .photo(
        PhotoAttachment(sizes: [
          PhotoSize(fileId: "photo-1", fileUniqueId: "u-1", width: 8, height: 8, fileSizeBytes: 64)
        ]),
        caption: caption
      )
    } else if voice {
      content = .voice(
        VoiceAttachment(fileId: "voice-1", durationSeconds: 3, mimeType: nil, fileSizeBytes: 64)
      )
    } else if let unsupported {
      content = .unsupported(kind: unsupported)
    } else {
      content = .text(text ?? "")
    }

    return IncomingMessage(
      updateId: 1,
      messageId: 1,
      userId: 7,
      chatId: -1_001,
      content: content,
      isEdited: false,
      chatKind: .supergroup,
      chatTitle: "Podlodka iOS Crew",
      messageThreadId: 12,
      replyToMessageId: replyToUserId == nil ? nil : 5,
      replyToUserId: replyToUserId,
      senderDisplayName: "Attendee"
    )
  }

  @Test func directModeAddressesEveryMessage() {
    // given — the shapes a group would ignore
    let shapes = [
      groupMessage(text: "just chatter"),
      groupMessage(photo: true),
      groupMessage(voice: true),
      groupMessage(unsupported: "stickers"),
    ]

    // when / then — in a DM the owner has nobody else to talk to
    for shape in shapes {
      #expect(resolver(identity: identity).isAddressed(shape, mode: .direct))
    }
  }

  @Test func aMentionInTextAddressesTheBot() {
    // given
    let message = groupMessage(text: "hey @claw_bot what is the schedule")

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group))
  }

  @Test func aMentionInACaptionAddressesTheBot() {
    // given
    let message = groupMessage(caption: "@claw_bot read this slide", photo: true)

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group))
  }

  @Test func aMentionIsMatchedCaseInsensitively() {
    // given — Telegram renders the handle however the sender typed it
    let message = groupMessage(text: "@Claw_Bot ping")

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group))
  }

  @Test func aReplyToTheBotAddressesIt() {
    // given — no mention at all, only a reply to something the bot said
    let message = groupMessage(text: "and the second one?", replyToUserId: 900)

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group))
  }

  @Test func aReplyToTheBotAddressesItEvenWithoutText() {
    // given — a voice note replying to the bot carries no text to mention it in
    let message = groupMessage(voice: true, replyToUserId: 900)

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group))
  }

  @Test func aCommandAddressedToTheBotAddressesIt() {
    // given
    let message = groupMessage(text: "/doctor@claw_bot")

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group))
  }

  @Test func aBareCommandAddressesTheBot() {
    // given — Telegram delivers an unqualified slash command to every bot in the room
    let message = groupMessage(text: "/help")

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group))
  }

  @Test func plainChatterDoesNotAddressTheBot() {
    // given
    let message = groupMessage(text: "anyone else stuck on the wifi")

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group) == false)
  }

  @Test func bareMediaDoesNotAddressTheBot() {
    // given — a sticker, a bare photo and a voice note, none of them naming the bot
    let shapes = [
      groupMessage(unsupported: "stickers"),
      groupMessage(photo: true),
      groupMessage(voice: true),
    ]

    // when / then
    for shape in shapes {
      #expect(resolver(identity: identity).isAddressed(shape, mode: .group) == false)
    }
  }

  @Test func aCommandForAnotherBotDoesNotAddressUs() {
    // given
    let message = groupMessage(text: "/doctor@other_bot")

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group) == false)
  }

  @Test func aMentionOfAnotherBotDoesNotAddressUs() {
    // given
    let message = groupMessage(text: "ask @other_bot about it")

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group) == false)
  }

  @Test func theHandleInsideALongerWordDoesNotAddressTheBot() {
    // given — a longer handle that merely starts with ours, and one that merely ends with it
    let longerHandle = groupMessage(text: "@claw_botanist posts plants")
    let trailingHandle = groupMessage(text: "mail me at hello@claw_bot")

    // when / then
    #expect(resolver(identity: identity).isAddressed(longerHandle, mode: .group) == false)
    #expect(resolver(identity: identity).isAddressed(trailingHandle, mode: .group) == false)
  }

  @Test func theHandleFollowedByPunctuationStillAddressesTheBot() {
    // given
    let message = groupMessage(text: "@claw_bot, can you summarize?")

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group))
  }

  @Test func aReplyToAnotherAttendeeDoesNotAddressTheBot() {
    // given
    let message = groupMessage(text: "same here", replyToUserId: 8)

    // when / then
    #expect(resolver(identity: identity).isAddressed(message, mode: .group) == false)
  }

  @Test func withoutAnIdentityNoGroupMessageIsAddressed() {
    // given — `getMe` answered nothing, which the boot guard rejects; the resolver still fails shut
    let message = groupMessage(text: "@claw_bot hello")

    // when / then
    #expect(resolver(identity: nil).isAddressed(message, mode: .group) == false)
  }
}
