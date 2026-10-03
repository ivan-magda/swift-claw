import Foundation

/// Literal Coder card blocks for Telegram Rich Markdown. Each block remains independently
/// bounded by encoded UTF-8 bytes and closed, so message boundaries cannot expose data as markup.
public enum CoderCardMarkdown {
  public static func field(label: String, value: String) -> String {
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
    let bodyByteLimit = ReplySplitter.limit - opening.utf8.count - closing.utf8.count
    var encodedBlocks: [String] = []
    var body = ""
    var bodyBytes = 0

    func append(_ encoded: String) {
      let encodedBytes = encoded.utf8.count
      if bodyBytes + encodedBytes > bodyByteLimit {
        encodedBlocks.append(opening + body + closing)
        body = ""
        bodyBytes = 0
      }
      body += encoded
      bodyBytes += encodedBytes
    }

    for character in value {
      let encoded = encode(String(character), preformatted: preformatted)
      if encoded.utf8.count <= bodyByteLimit {
        append(encoded)
      } else {
        for scalar in character.unicodeScalars {
          append(encode(String(scalar), preformatted: preformatted))
        }
      }
    }
    encodedBlocks.append(opening + body + closing)
    return encodedBlocks.joined(separator: "\n\n")
  }

  static func encode(_ text: String, preformatted: Bool) -> String {
    switch text {
    case "\n":
      preformatted ? "&#10;" : "<br>"
    case "\r":
      preformatted ? "&#13;" : "<br>"
    case "\r\n":
      preformatted ? "&#13;&#10;" : "<br>"
    default:
      text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    }
  }
}
