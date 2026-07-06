import Foundation

/// Telegram text command classification. Only a leading slash-token is authoritative; slash text
/// later in the message remains ordinary user content.
public enum Command: Sendable, Equatable {
  case start
  case stop
  case new
  case remember(RememberCommand)
  case memory(MemoryCommand)
  case schedule(ScheduleCommand)
  case pause(jobId: Int64?)
  case resume(jobId: Int64?)
  case runNow(jobId: Int64?)
  case cancelJob(jobId: Int64?)
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
    case "schedule":
      return .schedule(ScheduleCommand.parse(arguments: arguments))
    case "pause":
      return .pause(jobId: jobId(from: arguments))
    case "resume":
      return .resume(jobId: jobId(from: arguments))
    case "runnow":
      return .runNow(jobId: jobId(from: arguments))
    case "cancel":
      return .cancelJob(jobId: jobId(from: arguments))
    default:
      return .plain(text)
    }
  }

  /// nil ⇒ missing/invalid argument; the router replies with usage, never guesses.
  private static func jobId(from arguments: Substring) -> Int64? {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let id = Int64(trimmed), id > 0 else {
      return nil
    }
    return id
  }
}

/// Parsed `/schedule` arguments (spec §9). Bare `/schedule` and `/schedule list` both list;
/// anything else is the NL create text, passed verbatim to the parse call.
public enum ScheduleCommand: Sendable, Equatable {
  case list
  case create(text: String)

  public static func parse(arguments: Substring) -> ScheduleCommand {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.lowercased() == "list" {
      return .list
    }
    return .create(text: trimmed)
  }
}
