import Foundation

/// Literal Coder card blocks for Telegram Rich Markdown. Each block remains independently
/// bounded by encoded UTF-8 bytes and closed, so message boundaries cannot expose data as markup.
public enum CoderCardMarkdown {
  public static func field(_ label: String, _ value: String) -> String {
    blocks(value, opening: "<p><b>\(label):</b> ", closing: "</p>", preformatted: false)
  }

  public static func literal(_ value: String) -> String {
    blocks(value, opening: "<pre>", closing: "</pre>", preformatted: true)
  }

  /// Packs authored headings and the literal blocks above without splitting their delimiters.
  public static func split(text: String) -> [String] {
    var chunks: [String] = []
    var current = ""
    for block in text.components(separatedBy: "\n\n") where !block.isEmpty {
      for part in ReplySplitter.split(text: block) {
        let joined = current.isEmpty ? part : current + "\n\n" + part
        if joined.utf8.count > ReplySplitter.limit {
          chunks.append(current)
          current = part
        } else {
          current = joined
        }
      }
    }
    if !current.isEmpty {
      chunks.append(current)
    }
    return chunks
  }
}

// MARK: - Literal Encoding

private extension CoderCardMarkdown {
  static func blocks(
    _ value: String,
    opening: String,
    closing: String,
    preformatted: Bool
  ) -> String {
    let bodyLimit = ReplySplitter.limit - opening.utf8.count - closing.utf8.count
    var result: [String] = []
    var body = ""
    var count = 0
    func append(_ encoded: String) {
      let size = encoded.utf8.count
      if count + size > bodyLimit {
        result.append(opening + body + closing)
        body = ""
        count = 0
      }
      body += encoded
      count += size
    }
    for character in value {
      let encoded = encode(String(character), preformatted: preformatted)
      if encoded.utf8.count <= bodyLimit {
        append(encoded)
      } else {
        for scalar in character.unicodeScalars {
          append(encode(String(scalar), preformatted: preformatted))
        }
      }
    }
    result.append(opening + body + closing)
    return result.joined(separator: "\n\n")
  }

  static func encode(_ text: String, preformatted: Bool) -> String {
    switch text {
    case "\n": preformatted ? "&#10;" : "<br>"
    case "\r": preformatted ? "&#13;" : "<br>"
    case "\r\n": preformatted ? "&#13;&#10;" : "<br>"
    default:
      text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    }
  }
}
