import Foundation

/// Telegram text command classification. Only a leading slash-token is authoritative; slash text
/// later in the message remains ordinary user content.
public enum Command: Sendable, Equatable {
  case start
  case stop
  case new
  case remember(RememberCommand)
  case memory(MemoryCommand)
  case plain(String)

  public static func parse(_ text: String, botUsername: String?) -> Command {
    guard text.first == "/" else {
      return .plain(text)
    }

    let tokenEnd = text.firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
    let token = text[..<tokenEnd]
    let commandBody = token.dropFirst()
    guard commandBody.isEmpty == false else {
      return .plain(text)
    }

    let pieces = commandBody.split(
      separator: "@",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard let rawName = pieces.first, rawName.isEmpty == false else {
      return .plain(text)
    }

    if pieces.count == 2 {
      guard
        let botUsername,
        pieces[1].caseInsensitiveCompare(botUsername) == .orderedSame
      else {
        return .plain(text)
      }
    }

    let argumentsStart = tokenEnd < text.endIndex ? text.index(after: tokenEnd) : text.endIndex
    let arguments = text[argumentsStart...]

    switch String(rawName).lowercased() {
    case "start":
      return .start
    case "stop":
      return .stop
    case "new":
      return .new
    case "remember":
      return .remember(RememberCommand.parse(arguments: arguments))
    case "memory":
      return .memory(MemoryCommand.parse(arguments: arguments))
    default:
      return .plain(text)
    }
  }
}
