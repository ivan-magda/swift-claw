import Foundation

/// The one line-based rule for splitting a `---`-fenced document (a `SKILL.md`) into its
/// frontmatter block and its body. The scanner indexes a file and the loader later serves its
/// body: a second, independently written split would disagree on files the scanner accepted
/// (CRLF endings, a fence line with trailing spaces) or on a body containing a `---` horizontal
/// rule, and the loader would hand back the wrong text.
public enum FrontmatterFence {
  /// The raw text between the fences (never YAML-parsed here) and everything after the closing
  /// fence, with surrounding blank lines trimmed.
  public struct Document: Sendable, Equatable {
    public let frontmatter: String
    public let body: String

    public init(frontmatter: String, body: String) {
      self.frontmatter = frontmatter
      self.body = body
    }
  }

  /// Nil unless the first line is a fence AND a closing fence follows: a document that lost its
  /// fence has no frontmatter and no identifiable body, and guessing one is worse than failing.
  public static func split(_ text: String) -> Document? {
    let lines = text.components(separatedBy: "\n")
    guard let first = lines.first, isFence(first) else {
      return nil
    }

    var frontmatterLines: [String] = []
    for (offset, line) in lines.enumerated().dropFirst() {
      guard isFence(line) else {
        frontmatterLines.append(line)
        continue
      }

      let bodyLines = lines.dropFirst(offset + 1)
      return Document(
        frontmatter: frontmatterLines.joined(separator: "\n"),
        body: bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }

    return nil
  }

  /// A fence is a line whose trimmed text is exactly `---`, which is what makes CRLF endings and
  /// trailing whitespace non-events.
  private static func isFence(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
  }
}
