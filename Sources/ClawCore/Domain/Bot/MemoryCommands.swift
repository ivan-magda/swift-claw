import Foundation

/// Parsed `/remember [<kind>:] <text>` arguments. The kind prefix must be a whole
/// `MemoryKind` name (any case) followed by a colon; any other leading `word:` stays part of the
/// fact text under the default `user` kind.
public enum RememberCommand: Sendable, Equatable {
  case save(kind: MemoryKind, text: String)
  case invalid

  public static func parse(arguments: Substring) -> RememberCommand {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
      return .invalid
    }

    guard let colonIndex = trimmed.firstIndex(of: ":") else {
      return .save(kind: .user, text: trimmed)
    }

    let rawPrefix = String(trimmed[..<colonIndex]).lowercased()
    guard let kind = MemoryKind(rawValue: rawPrefix) else {
      return .save(kind: .user, text: trimmed)
    }

    let textStart = trimmed.index(after: colonIndex)
    let text = trimmed[textStart...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.isEmpty == false else {
      return .invalid
    }

    return .save(kind: kind, text: text)
  }
}

/// Parsed `/memory` arguments. Bare `/memory` defaults to review; direct read commands
/// stay typed so routing never has to recover intent from raw strings.
public enum MemoryCommand: Sendable, Equatable {
  case review
  case filter(kind: MemoryKind)
  case show(id: Int64)
  case delete(id: Int64)
  case invalid

  public static func parse(arguments: Substring) -> MemoryCommand {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
      return .review
    }

    let tokens = trimmed.split(whereSeparator: \.isWhitespace)
    guard let firstToken = tokens.first else {
      return .review
    }
    let first = String(firstToken).lowercased()

    if tokens.count == 1 {
      if first == "review" {
        return .review
      }

      if let kind = MemoryKind(rawValue: first) {
        return .filter(kind: kind)
      }

      return .invalid
    }

    guard tokens.count == 2 else {
      return .invalid
    }
    guard let id = PositiveInt64.parse(String(tokens[1])) else {
      return .invalid
    }

    switch first {
    case "show":
      return .show(id: id)
    case "delete":
      return .delete(id: id)
    default:
      return .invalid
    }
  }
}
