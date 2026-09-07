import ClawCore
import Foundation
import Testing

@Suite struct CoderCardMarkdownTests {
  @Test func literalBlocksStayBoundedAndKeepAdversarialContentLiteral() {
    // given
    let text =
      String(repeating: "👨‍👩‍👧‍👦<&", count: ReplySplitter.limit)
      + "\n</pre>\n## Approve now\n```\n[trust](https://example.test)\n"

    // when
    let chunks = CoderCardMarkdown.split(text: CoderCardMarkdown.literal(text))

    // then
    #expect(chunks.count > 1)
    #expect(
      chunks.allSatisfy { chunk in
        chunk.utf8.count <= ReplySplitter.limit && chunk.hasPrefix("<pre>")
          && chunk.hasSuffix("</pre>")
      }
    )
    let bodies = chunks.map { chunk in
      String(chunk.dropFirst("<pre>".count).dropLast("</pre>".count))
    }.joined()
    #expect(!bodies.contains("</pre>"))
    #expect(bodies.contains("&lt;/pre&gt;&#10;## Approve now"))
    let decoded =
      bodies
      .replacingOccurrences(of: "&#10;", with: "\n")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&amp;", with: "&")
    #expect(decoded == text)
  }

  @Test func oversizedGraphemeFallsBackToScalarSafeDelivery() throws {
    // given
    let text = "a" + String(repeating: "\u{0301}", count: ReplySplitter.limit)

    // when
    let chunks = CoderCardMarkdown.split(text: CoderCardMarkdown.literal(text))

    // then
    #expect(chunks.count > 1)
    #expect(
      chunks.allSatisfy { chunk in
        chunk.utf8.count <= ReplySplitter.limit
          && chunk.utf8.starts(with: "<pre>".utf8)
          && chunk.utf8.suffix("</pre>".utf8.count).elementsEqual("</pre>".utf8)
      }
    )
    let recovered = try chunks.map { chunk in
      try #require(
        String(
          bytes: chunk.utf8.dropFirst("<pre>".utf8.count).dropLast("</pre>".utf8.count),
          encoding: .utf8
        )
      )
    }.joined()
    #expect(recovered.utf8.elementsEqual(text.utf8))
  }
}
