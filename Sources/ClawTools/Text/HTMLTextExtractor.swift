import Foundation

/// A deliberately naive pure-Swift HTML-to-text strip (§7.2): drop script/style/comments, strip
/// tags, decode a minimal entity set, collapse whitespace. Readability extraction is out of scope.
public enum HTMLTextExtractor {
  public static func extractText(fromHTML html: String) -> String {
    var text = html

    for pattern in [
      "<script[^>]*>[\\s\\S]*?</script>",
      "<style[^>]*>[\\s\\S]*?</style>",
      "<!--[\\s\\S]*?-->",
    ] {
      text = text.replacingOccurrences(
        of: pattern,
        with: " ",
        options: [.regularExpression, .caseInsensitive]
      )
    }
    text = text.replacingOccurrences(of: "</?[^>]+>", with: " ", options: .regularExpression)

    // Minimal entity set; &amp; last so freed entities aren't double-decoded.
    for (entity, character) in [
      ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
      ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
    ] {
      text = text.replacingOccurrences(of: entity, with: character)
    }

    text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
