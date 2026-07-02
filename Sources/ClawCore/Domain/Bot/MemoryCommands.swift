import Foundation

/// Parsed `/remember [<kind>:] <text>` arguments (spec §8.3). The kind prefix must be a whole
/// `MemoryKind` name (any case) followed by a colon; any other leading `word:` stays part of the
/// fact text under the default `user` kind.
public enum RememberCommand: Sendable, Equatable {
  case save(kind: MemoryKind, text: String)
  case invalid

  public static func parse(arguments: Substring) -> RememberCommand {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return .invalid }

    guard let colonIndex = trimmed.firstIndex(of: ":") else {
      return .save(kind: .user, text: trimmed)
    }

    let rawPrefix = String(trimmed[..<colonIndex]).lowercased()
    guard let kind = MemoryKind(rawValue: rawPrefix) else {
      return .save(kind: .user, text: trimmed)
    }

    let textStart = trimmed.index(after: colonIndex)
    let text = trimmed[textStart...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.isEmpty == false else { return .invalid }
    return .save(kind: kind, text: text)
  }
}
