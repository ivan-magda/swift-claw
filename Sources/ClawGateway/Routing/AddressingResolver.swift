import ClawCore
import Foundation

/// Decides whether one inbound message is talking to the bot.
///
/// In a DM the answer is always yes — the owner has nobody else to address. In a group the bot is
/// one participant among many, so it acts only on a message that names it: an `@handle` anywhere in
/// the text or a photo caption, a slash command it recognizes, or a reply to something it said
/// itself. Everything else is overheard, not asked. Without a known identity nothing in a group is
/// addressed, so a daemon that somehow ran without one stays quiet instead of answering everyone.
public struct AddressingResolver: Sendable {
  private let identity: BotIdentity?

  public init(identity: BotIdentity?) {
    self.identity = identity
  }

  public func isAddressed(_ message: IncomingMessage, mode: ChatMode) -> Bool {
    switch mode {
    case .direct:
      return true
    case .group:
      return isAddressedInGroup(message)
    }
  }
}

// MARK: - Group Addressing

private extension AddressingResolver {
  func isAddressedInGroup(_ message: IncomingMessage) -> Bool {
    guard let identity else {
      return false
    }
    if message.replyToUserId == identity.id {
      return true
    }
    guard let written = writtenText(message.content) else {
      return false
    }
    return mentions(identity.username, in: written) || isCommandForBot(written, identity: identity)
  }

  /// What a human typed: a message body, or a photo's caption. A voice note and unsupported media
  /// carry none, so only a reply can address the bot with them.
  func writtenText(_ content: IncomingMessage.Content) -> String? {
    switch content {
    case .text(let text):
      text
    case .photo(_, let caption):
      caption
    case .voice, .unsupported:
      nil
    }
  }

  /// A leading slash-token this build recognizes. `/cmd@someone_else` and an unknown verb both fall
  /// through to `.plain`, which is precisely the "not for us" answer — the handle match already
  /// lives in the parser and is not re-implemented here.
  func isCommandForBot(_ text: String, identity: BotIdentity) -> Bool {
    if case .plain = Command.parse(text, botUsername: identity.username) {
      return false
    }
    return true
  }

  /// `@handle` as a whole handle. Telegram handles are ASCII letters, digits and underscores, so a
  /// neighbouring one of those means the hit is part of a longer name (`@claw_botanist`) or of an
  /// address (`hello@claw_bot`) rather than a mention of this bot.
  func mentions(_ username: String?, in text: String) -> Bool {
    guard let username else {
      return false
    }
    let handle = "@" + username
    var searched = text.startIndex..<text.endIndex
    while let hit = text.range(of: handle, options: .caseInsensitive, range: searched) {
      let leading =
        hit.lowerBound == text.startIndex
        ? nil : text[text.index(before: hit.lowerBound)]
      let trailing = hit.upperBound == text.endIndex ? nil : text[hit.upperBound]
      if isHandleCharacter(leading) == false, isHandleCharacter(trailing) == false {
        return true
      }
      searched = hit.upperBound..<text.endIndex
    }
    return false
  }

  func isHandleCharacter(_ character: Character?) -> Bool {
    guard let character else {
      return false
    }
    return character.isLetter || character.isNumber || character == "_"
  }
}
