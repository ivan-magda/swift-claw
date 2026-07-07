import Foundation

/// A deliberately naive pure-Swift HTML-to-text strip (§7.2): drop script/style/comments, strip
/// tags, decode a minimal entity set, collapse whitespace. Readability extraction is out of scope.
///
/// Implemented as a single **linear** left-to-right scan — deliberately not a backtracking regex
/// over the body. A hostile page (a 2 MiB run of unclosed `<script>`, or a long run of `\r`) is
/// O(n) here; the old lazy `<script>…[\s\S]*?…</script>` / `\s*\n\s*` regexes were O(n²) on the same
/// input and pinned a CPU core for minutes, with no way for the tool timeout to interrupt the
/// synchronous work. Malicious servers are in scope, so this path must not blow up.
public enum HTMLTextExtractor {
  public static func extractText(fromHTML html: String) -> String {
    let stripped = stripMarkup(html)
    let decoded = decodeEntities(stripped)
    return collapseWhitespace(decoded)
  }
}

// MARK: - Markup Stripping

private extension HTMLTextExtractor {
  // Keywords are stored lowercase and matched case-insensitively via `matchesFolded`.
  static let commentOpen: [Unicode.Scalar] = ["<", "!", "-", "-"]
  static let commentClose: [Unicode.Scalar] = ["-", "-", ">"]
  static let scriptName: [Unicode.Scalar] = ["s", "c", "r", "i", "p", "t"]
  static let styleName: [Unicode.Scalar] = ["s", "t", "y", "l", "e"]
  static let scriptClose: [Unicode.Scalar] = ["<", "/", "s", "c", "r", "i", "p", "t"]
  static let styleClose: [Unicode.Scalar] = ["<", "/", "s", "t", "y", "l", "e"]

  /// The raw-text elements whose full body is dropped, each with its matching close keyword.
  static let rawElements: [(name: [Unicode.Scalar], close: [Unicode.Scalar])] = [
    (scriptName, scriptClose),
    (styleName, styleClose),
  ]

  /// Drops comments and the FULL body of `script`/`style` elements, and replaces every other tag
  /// with a single space. Each scalar is visited at most once by the outer loop; the bounded
  /// look-ahead keeps the whole pass linear even when a close token never appears (the unclosed
  /// `<script>` case just scans to EOF once and stops).
  static func stripMarkup(_ html: String) -> String {
    let scalars = Array(html.unicodeScalars)
    let count = scalars.count
    var output = String.UnicodeScalarView()
    var index = 0

    while index < count {
      guard scalars[index] == "<" else {
        output.append(scalars[index])
        index += 1
        continue
      }

      if matchesFolded(commentOpen, in: scalars, at: index) {
        // The closing `-->` may reuse the opener's dashes, so search from just past `<!`. This keeps
        // the content after an abruptly-closed comment (`<!-->`, `<!--->`), as browsers do, instead
        // of dropping the rest of the page; a genuinely unclosed `<!--` still runs to EOF.
        index = skip(scalars, from: index + 2, past: commentClose)
        output.append(" ")
        continue
      }

      if let element = rawElementOpening(scalars, tagAt: index) {
        index = skipRawElement(scalars, from: index, close: element.close)
        output.append(" ")
        continue
      }

      guard isTagStart(scalars, after: index) else {
        // A `<` not followed by a tag-name char / `/` / `!` / `?` is literal text (`a < b`), per the
        // HTML tokenizer — emitting it verbatim avoids swallowing the tail of a truncated page.
        output.append(scalars[index])
        index += 1
        continue
      }

      index = skipToTagEnd(scalars, from: index)
      output.append(" ")
    }

    return String(output)
  }

  /// The raw element whose opening tag starts at `index`, else nil. The name must be followed by a
  /// real terminator, so `<scripting>` is an ordinary tag rather than a `script` raw element.
  static func rawElementOpening(
    _ scalars: [Unicode.Scalar],
    tagAt index: Int
  ) -> (name: [Unicode.Scalar], close: [Unicode.Scalar])? {
    let nameStart = index + 1

    guard nameStart < scalars.count, scalars[nameStart] != "/" else {
      return nil  // a close tag `</…>` never opens a raw element
    }

    return rawElements.first { element in
      opensRawElement(element.name, in: scalars, atNameStart: nameStart)
    }
  }

  /// True when `name` starts at `nameStart` and is followed by a name terminator — so the enclosing
  /// `<name…>` opens a raw element (`<script>`) rather than an ordinary tag (`<scripting>`).
  static func opensRawElement(
    _ name: [Unicode.Scalar],
    in scalars: [Unicode.Scalar],
    atNameStart nameStart: Int
  ) -> Bool {
    matchesFolded(name, in: scalars, at: nameStart)
      && isNameTerminator(scalars, at: nameStart + name.count)
  }

  /// From the opening `<` of a `script`/`style` element, skip its opening tag, then its body up to
  /// the matching close keyword, then that close tag's `>`. Returns EOF if the close never appears.
  static func skipRawElement(
    _ scalars: [Unicode.Scalar],
    from tagStart: Int,
    close: [Unicode.Scalar]
  ) -> Int {
    let count = scalars.count
    var index = skipToTagEnd(scalars, from: tagStart)  // past the opening tag's `>`

    while index < count, isRawElementClose(close, in: scalars, at: index) == false {
      index += 1
    }

    guard index < count else {
      return count
    }

    return skipToTagEnd(scalars, from: index + close.count)  // past the close tag's `>`
  }

  /// True when `close` (e.g. `</script`) matches at `index` AND is followed by a name terminator, so
  /// `</scriptx>` does not close the element — the close-side mirror of `opensRawElement`. Without it
  /// a fake close leaks the raw body between it and the real `</script>` into the extracted text.
  static func isRawElementClose(
    _ close: [Unicode.Scalar],
    in scalars: [Unicode.Scalar],
    at index: Int
  ) -> Bool {
    matchesFolded(close, in: scalars, at: index)
      && isNameTerminator(scalars, at: index + close.count)
  }

  /// Advance from `start` to just past the next `>`, or to EOF if there is none.
  static func skipToTagEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
    let count = scalars.count
    var index = start

    while index < count, scalars[index] != ">" {
      index += 1
    }

    return index < count ? index + 1 : count
  }

  /// Advance from `start` to just past the next occurrence of `keyword`, or to EOF if absent.
  static func skip(
    _ scalars: [Unicode.Scalar],
    from start: Int,
    past keyword: [Unicode.Scalar]
  ) -> Int {
    let count = scalars.count
    var index = start

    while index < count {
      if matchesFolded(keyword, in: scalars, at: index) {
        return index + keyword.count
      }
      index += 1
    }

    return count
  }

  static func isNameTerminator(_ scalars: [Unicode.Scalar], at pos: Int) -> Bool {
    guard pos < scalars.count else {
      return true  // `<script` at EOF: still a raw element with no body
    }

    let scalar = scalars[pos]
    return scalar == ">" || scalar == "/" || isASCIIWhitespace(scalar)
  }

  /// Whether the `<` at `index` opens a tag: HTML starts a tag only when `<` is followed by a
  /// tag-name letter, `/`, `!`, or `?` — otherwise the `<` is ordinary text.
  static func isTagStart(_ scalars: [Unicode.Scalar], after index: Int) -> Bool {
    let next = index + 1

    guard next < scalars.count else {
      return false  // a trailing `<` is literal text
    }

    let scalar = scalars[next]
    return isASCIILetter(scalar) || scalar == "/" || scalar == "!" || scalar == "?"
  }

  static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
  }
}

// MARK: - Text Normalization

private extension HTMLTextExtractor {
  static let entities: [(token: [Unicode.Scalar], replacement: Unicode.Scalar)] = [
    (Array("&nbsp;".unicodeScalars), " "),
    (Array("&lt;".unicodeScalars), "<"),
    (Array("&gt;".unicodeScalars), ">"),
    (Array("&quot;".unicodeScalars), "\""),
    (Array("&#39;".unicodeScalars), "'"),
    (Array("&apos;".unicodeScalars), "'"),
    (Array("&amp;".unicodeScalars), "&"),
  ]

  /// Left-to-right longest-match decode: advancing past a consumed entity means a freed `&` (from
  /// `&amp;`) is never re-scanned, so `&amp;lt;` decodes to `&lt;`, not `<` (no double-decode).
  static func decodeEntities(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    let count = scalars.count
    var output = String.UnicodeScalarView()
    var index = 0

    while index < count {
      guard scalars[index] == "&" else {
        output.append(scalars[index])
        index += 1
        continue
      }

      if let entity = entities.first(where: { matchesExact($0.token, in: scalars, at: index) }) {
        output.append(entity.replacement)
        index += entity.token.count
      } else {
        output.append(scalars[index])
        index += 1
      }
    }

    return String(output)
  }

  /// Collapse each run of ASCII whitespace to a single `\n` (if the run held a newline) or ` `,
  /// dropping leading and trailing whitespace — the linear equivalent of the old `[ \t]+` +
  /// `\s*\n\s*` regex pair, without their backtracking.
  static func collapseWhitespace(_ text: String) -> String {
    var output = String.UnicodeScalarView()
    var pendingNewline = false
    var pendingSpace = false
    var emittedNonSpace = false

    for scalar in text.unicodeScalars {
      guard isASCIIWhitespace(scalar) == false else {
        if scalar == "\n" {
          pendingNewline = true
        } else {
          pendingSpace = true
        }
        continue
      }

      if emittedNonSpace {
        if pendingNewline {
          output.append("\n")
        } else if pendingSpace {
          output.append(" ")
        }
      }

      output.append(scalar)
      emittedNonSpace = true
      pendingNewline = false
      pendingSpace = false
    }

    return String(output)
  }
}

// MARK: - Scalar Helpers

private extension HTMLTextExtractor {
  /// Case-insensitive (ASCII-folded) match of a lowercase `keyword` against `scalars` at `pos`.
  static func matchesFolded(
    _ keyword: [Unicode.Scalar],
    in scalars: [Unicode.Scalar],
    at pos: Int
  ) -> Bool {
    guard pos + keyword.count <= scalars.count else {
      return false
    }

    for offset in 0..<keyword.count where asciiLower(scalars[pos + offset]) != keyword[offset] {
      return false
    }

    return true
  }

  /// Case-sensitive match — HTML entity names are case-sensitive (`&AMP;` is not `&amp;`).
  static func matchesExact(
    _ keyword: [Unicode.Scalar],
    in scalars: [Unicode.Scalar],
    at pos: Int
  ) -> Bool {
    guard pos + keyword.count <= scalars.count else {
      return false
    }

    for offset in 0..<keyword.count where scalars[pos + offset] != keyword[offset] {
      return false
    }

    return true
  }

  static func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case " ", "\t", "\n", "\r", "\u{0B}", "\u{0C}":
      true
    default:
      false
    }
  }

  static func asciiLower(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    if ("A"..."Z").contains(scalar) {
      return Unicode.Scalar(scalar.value + 32) ?? scalar
    }
    return scalar
  }
}
