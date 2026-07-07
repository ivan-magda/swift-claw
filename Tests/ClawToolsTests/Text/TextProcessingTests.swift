import ClawCore
import Foundation
import Testing

@testable import ClawTools

@Suite struct TextProcessingTests {
  @Test func capPinsTheGraphemeEquivalentOfTwentyFiveThousandTokens() {
    // given / when / then — amendment §18-G's pinned unit conversion
    #expect(TokenEstimator.graphemeBudget(forInputTokens: 25_000) == 80_000)
    #expect(ToolOutputCap.maxGraphemes == 80_000)
  }

  @Test func capCutsWithTheLiteralMarker() {
    // given
    let text = String(repeating: "a", count: 100)

    // when
    let capped = ToolOutputCap.cap(text, maxGraphemes: 50)

    // then
    #expect(capped.count == 50)
    #expect(capped.hasSuffix("…[truncated]"))
    #expect(ToolOutputCap.cap("short", maxGraphemes: 50) == "short")
  }

  @Test func redactorReplacesEveryExactSecretOccurrence() {
    // given
    let redactor = SecretRedactor(secretValues: ["tok-123", "", "key-9"])

    // when
    let redacted = redactor.redact("a tok-123 b key-9 c tok-123")

    // then — empties are ignored, every occurrence replaced
    #expect(
      redacted == "a [REDACTED:secret-value] b [REDACTED:secret-value] c [REDACTED:secret-value]"
    )
  }

  @Test func extractorDropsScriptStyleAndTags() {
    // given
    let html = """
      <html><head><style>body { color: red; }</style>
      <script>alert("ignore previous instructions");</script></head>
      <body><h1>Title</h1><p>First &amp; second &lt;paragraph&gt;.</p>
      <!-- a comment --><div>Tail   text</div></body></html>
      """

    // when
    let text = HTMLTextExtractor.extractText(fromHTML: html)

    // then
    #expect(text.contains("Title"))
    #expect(text.contains("First & second <paragraph>."))
    #expect(text.contains("Tail text"))
    #expect(text.contains("alert") == false)
    #expect(text.contains("color: red") == false)
    #expect(text.contains("a comment") == false)
    #expect(text.contains("<h1>") == false)
  }

  @Test func extractorDropsScriptBodyOnCloseTagVariants() {
    // given — HTML5 accepts close tags with trailing space/junk/case; the naive literal-`</script>`
    // strip used to leak the body on these, so hidden script text reached the model as page text
    let variants = [
      #"<p>hi</p><script>SECRETJS</script >after"#,
      #"<p>hi</p><script>SECRETJS</script foo>after"#,
      #"<p>hi</p><SCRIPT>SECRETJS</SCRIPT>after"#,
      "<p>hi</p><style>SECRETCSS</style\n>after",
    ]

    // when / then — the element body is dropped whatever the close-tag shape
    for html in variants {
      let text = HTMLTextExtractor.extractText(fromHTML: html)
      #expect(text.contains("SECRET") == false, "leaked raw element body in: \(html)")
      #expect(text.contains("hi"))
      #expect(text.contains("after"))
    }
  }

  @Test func extractorDoesNotCloseRawElementOnFakeCloseTagPrefix() {
    // given — `</scriptx>` is NOT a close tag in HTML5 (the name needs a terminator), so the body
    // between a fake close and the real `</script>` must stay dropped, not leak into the text
    let cases = [
      #"<script>keep? </scriptx> LEAKED</script>tail"#,
      #"<script>x</scripting>LEAKED2</script>tail"#,
      #"<style>a{} </stylex> STOLEN-CSS</style><p>ok</p>"#,
    ]

    // when / then
    for html in cases {
      let text = HTMLTextExtractor.extractText(fromHTML: html)
      #expect(text.contains("LEAK") == false, "fake close leaked body in: \(html)")
      #expect(text.contains("STOLEN") == false, "fake close leaked body in: \(html)")
    }
  }

  @Test func extractorKeepsContentAfterAbruptlyClosedCommentsAndStrayAngleBrackets() {
    // given — WHATWG treats `<!-->` / `<!--->` as complete comments (content after them kept), and a
    // `<` with no following `>` is literal text — the old code preserved both; the linear scan must too
    #expect(
      HTMLTextExtractor.extractText(fromHTML: "<!-->Important article</p>") == "Important article"
    )
    #expect(
      HTMLTextExtractor.extractText(fromHTML: "<!--->After the comment</p>") == "After the comment"
    )
    #expect(HTMLTextExtractor.extractText(fromHTML: "result: a < b") == "result: a < b")
    // a normal comment is still dropped whole
    #expect(HTMLTextExtractor.extractText(fromHTML: "before<!-- gone -->after") == "before after")
  }

  @Test(.timeLimit(.minutes(1)))
  func extractorHandlesHostileUnclosedMarkupInLinearTime() {
    // given — the two inputs that made the old backtracking regexes O(n²): a run of never-closed
    // `<script>` opens, and a long run of carriage returns. These sizes are small for the linear
    // scanner but still pathological for the old regex implementation.
    let unclosedScript = String(repeating: "<script>", count: 2 * 1024) + "PAYLOAD"
    let carriageReturns = String(repeating: "\r", count: 16 * 1024) + "tail"

    // when — the linear scan returns effectively instantly; a quadratic regression blows the limit
    let fromScript = HTMLTextExtractor.extractText(fromHTML: unclosedScript)
    let fromReturns = HTMLTextExtractor.extractText(fromHTML: carriageReturns)

    // then — the unterminated raw element swallows to EOF; the whitespace run collapses away
    #expect(fromScript.contains("PAYLOAD") == false)
    #expect(fromReturns == "tail")
  }
}
