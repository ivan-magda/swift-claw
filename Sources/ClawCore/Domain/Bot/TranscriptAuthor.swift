/// Who said a line, as a shared transcript records it.
///
/// One topic interleaves many speakers, so a stored group line names its author; a DM has exactly
/// one speaker, so it names nobody. The label is rendered where the message is persisted rather
/// than where context is built, so a recall hit pulled out of history still carries who said it.
public struct TranscriptAuthor: Sendable, Equatable {
  /// Divides the author from what they said. A display name carrying it is rewritten before the
  /// join, so a single line can never present itself as two speakers.
  public static let separator = ": "

  public let label: String

  public init(displayName: String?, userId: Int64) {
    let sanitized = Self.sanitize(displayName)
    label = sanitized.isEmpty ? "user \(userId)" : sanitized
  }

  public init(message: IncomingMessage) {
    self.init(displayName: message.senderDisplayName, userId: message.userId)
  }

  public func prefixing(_ text: String) -> String {
    label + Self.separator + text
  }

  /// Folds the separator and every line break into spaces, then collapses the runs — a name is one
  /// plain line or it is not usable as a label.
  private static func sanitize(_ displayName: String?) -> String {
    guard let displayName else {
      return ""
    }
    let flattened = displayName.map { char in
      char == ":" || char.isNewline ? " " : char
    }
    return String(flattened)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }
}

extension ChatMode {
  /// The text as this conversation's transcript keeps it: a DM line is exactly what was typed, a
  /// group line is prefixed with its speaker.
  public func transcriptText(_ text: String, author: TranscriptAuthor) -> String {
    switch self {
    case .direct: text
    case .group: author.prefixing(text)
    }
  }
}
