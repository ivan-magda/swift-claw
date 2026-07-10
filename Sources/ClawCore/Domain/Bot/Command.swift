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
  case help
  case plain(String)

  public static func parse(_ text: String, botUsername: String?) -> Command {
    guard let token = slashToken(in: text, botUsername: botUsername) else {
      return .plain(text)
    }
    return command(named: token.name, arguments: token.arguments, originalText: text)
  }
}

// MARK: - Slash-Token Parsing

private extension Command {
  /// The leading slash-token, split into a lowercased command name and its argument tail. nil when
  /// the text carries no authoritative slash-token (or one addressed to a different bot).
  static func slashToken(
    in text: String,
    botUsername: String?
  ) -> (name: String, arguments: Substring)? {
    guard text.first == "/" else {
      return nil
    }

    let tokenEnd = text.firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
    let commandBody = text[..<tokenEnd].dropFirst()
    guard commandBody.isEmpty == false else {
      return nil
    }

    let pieces = commandBody.split(
      separator: "@",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard let rawName = pieces.first, rawName.isEmpty == false else {
      return nil
    }

    if pieces.count == 2 {
      guard
        let botUsername,
        pieces[1].caseInsensitiveCompare(botUsername) == .orderedSame
      else {
        return nil
      }
    }

    let argumentsStart = tokenEnd < text.endIndex ? text.index(after: tokenEnd) : text.endIndex
    return (name: String(rawName).lowercased(), arguments: text[argumentsStart...])
  }

  static func command(named name: String, arguments: Substring, originalText: String) -> Command {
    switch name {
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
    case "help":
      return .help
    default:
      return .plain(originalText)
    }
  }

  /// nil ⇒ missing/invalid argument; the router replies with usage, never guesses.
  static func jobId(from arguments: Substring) -> Int64? {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let id = Int64(trimmed), id > 0 else {
      return nil
    }
    return id
  }
}

/// Parsed `/schedule` arguments. Bare `/schedule` and `/schedule list` both list;
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
