import ClawCore
import Foundation
import Testing

@testable import ClawAuth

@Suite struct ChatGPTWireValuesTests {
  // MARK: - Positive Integer: Accepted Encodings

  @Test(arguments: [
    (JSONValue.number(5), 5),
    (JSONValue.number(1), 1),
    (JSONValue.number(900), 900),
    (JSONValue.string("5"), 5),
    (JSONValue.string("1"), 1),
    (JSONValue.string("3600"), 3600),
    (JSONValue.string("007"), 7),
  ])
  func positiveIntegerAcceptsNumbersAndDecimalStrings(value: JSONValue, expected: Int) {
    // given / when
    let parsed = ChatGPTWireValues.positiveInteger(value)

    // then
    #expect(parsed == expected)
  }

  // MARK: - Positive Integer: Rejected Values

  @Test(arguments: [
    JSONValue.number(0),
    JSONValue.number(-1),
    JSONValue.number(-5.5),
    JSONValue.string("0"),
    JSONValue.string("-1"),
  ])
  func positiveIntegerRejectsZeroAndNegatives(value: JSONValue) {
    // given / when / then
    #expect(ChatGPTWireValues.positiveInteger(value) == nil)
  }

  @Test(arguments: [
    JSONValue.number(5.5),
    JSONValue.number(0.9),
    JSONValue.string("5.5"),
    JSONValue.string("5.0"),
  ])
  func positiveIntegerRejectsFractions(value: JSONValue) {
    // given / when / then
    #expect(ChatGPTWireValues.positiveInteger(value) == nil)
  }

  @Test(arguments: [
    JSONValue.number(1e30),
    JSONValue.number(Double(Int.max) * 4),
    JSONValue.number(.infinity),
    JSONValue.number(.nan),
    JSONValue.string("99999999999999999999999"),
  ])
  func positiveIntegerRejectsValuesOutsideIntegerRange(value: JSONValue) {
    // given / when / then
    #expect(ChatGPTWireValues.positiveInteger(value) == nil)
  }

  @Test(arguments: [
    JSONValue.string(""),
    JSONValue.string(" 5"),
    JSONValue.string("5 "),
    JSONValue.string("+5"),
    JSONValue.string("5s"),
    JSONValue.string("0x10"),
    // Swift's own Int(_:) accepts non-ASCII digit shapes; the wire contract is ASCII decimal only.
    JSONValue.string("٥"),
    JSONValue.bool(true),
    JSONValue.null,
    JSONValue.array([.number(5)]),
    JSONValue.object(["interval": .number(5)]),
  ])
  func positiveIntegerRejectsNonDecimalEncodings(value: JSONValue) {
    // given / when / then
    #expect(ChatGPTWireValues.positiveInteger(value) == nil)
  }

  // MARK: - Header-Safe Token: Accepted

  @Test(arguments: [
    "abc123",
    "eyJhbGciOiJub25lIn0.eyJhIjoxfQ.sig",
    "acct_-._~+/=",
  ])
  func headerSafeTokenAcceptsBoundedAsciiWithoutWhitespace(raw: String) {
    // given / when
    let accepted = ChatGPTWireValues.headerSafeToken(raw, maxBytes: 256)

    // then
    #expect(accepted == raw)
  }

  @Test func headerSafeTokenAcceptsAValueExactlyAtTheByteCap() {
    // given
    let exact = String(repeating: "a", count: 256)

    // when / then
    #expect(ChatGPTWireValues.headerSafeToken(exact, maxBytes: 256) == exact)
  }

  // MARK: - Header-Safe Token: Rejected

  @Test func headerSafeTokenRejectsAValueOneByteOverTheCap() {
    // given
    let oversized = String(repeating: "a", count: 257)

    // when / then
    #expect(ChatGPTWireValues.headerSafeToken(oversized, maxBytes: 256) == nil)
  }

  @Test(arguments: [
    "",
    "has space",
    "has\ttab",
    "has\nnewline",
    "has\r\ncrlf",
    "trailing ",
    " leading",
    "nul\u{0}byte",
    "esc\u{1B}[31m",
    "del\u{7F}",
    // A C1 control is invisible in a terminal and is not ASCII; both bars must reject it.
    "c1\u{85}next-line",
    "non-ascii-é",
    "emoji-🙂",
    // A non-breaking space is whitespace that an ASCII-only bar alone would not catch.
    "nbsp\u{A0}space",
  ])
  func headerSafeTokenRejectsEmptyNonAsciiWhitespaceAndControls(raw: String) {
    // given / when / then
    #expect(ChatGPTWireValues.headerSafeToken(raw, maxBytes: 256) == nil)
  }

  @Test func headerSafeTokenMeasuresTheCapInUtf8BytesNotCharacters() {
    // given
    // Four scalars, but eight UTF-8 bytes: a character count would wrongly admit this.
    let multiByte = "ééée"

    // when / then
    #expect(multiByte.count == 4)
    #expect(multiByte.utf8.count == 7)
    #expect(ChatGPTWireValues.headerSafeToken(multiByte, maxBytes: 6) == nil)
  }

  // MARK: - Control-Free: Accepted

  @Test(arguments: [
    "ABCD-1234",
    // Unlike a header value, a printed user code may carry spaces and non-ASCII text.
    "ABCD 1234",
    "código-é",
  ])
  func controlFreeAcceptsPrintableTextIncludingSpaces(raw: String) {
    // given / when
    let accepted = ChatGPTWireValues.controlFree(raw, maxBytes: 128)

    // then
    #expect(accepted == raw)
  }

  @Test func controlFreeAcceptsAValueExactlyAtTheByteCap() {
    // given
    let exact = String(repeating: "A", count: 128)

    // when / then
    #expect(ChatGPTWireValues.controlFree(exact, maxBytes: 128) == exact)
  }

  // MARK: - Control-Free: Rejected

  @Test func controlFreeRejectsAValueOneByteOverTheCap() {
    // given
    let oversized = String(repeating: "A", count: 129)

    // when / then
    #expect(ChatGPTWireValues.controlFree(oversized, maxBytes: 128) == nil)
  }

  @Test(arguments: [
    "",
    "code\u{0}nul",
    "code\u{7}bell",
    "code\ttab",
    "code\nnewline",
    "code\rreturn",
    "code\u{1B}[2Jclear",
    "code\u{7F}del",
    "code\u{9B}csi",
  ])
  func controlFreeRejectsEmptyAndControlBearingText(raw: String) {
    // given / when / then
    #expect(ChatGPTWireValues.controlFree(raw, maxBytes: 128) == nil)
  }

  @Test func controlFreeMeasuresTheCapInUtf8BytesNotCharacters() {
    // given
    let multiByte = "ééé"

    // when / then
    #expect(multiByte.count == 3)
    #expect(multiByte.utf8.count == 6)
    #expect(ChatGPTWireValues.controlFree(multiByte, maxBytes: 5) == nil)
    #expect(ChatGPTWireValues.controlFree(multiByte, maxBytes: 6) == multiByte)
  }

  // MARK: - Safe Remote Diagnostic: Sanitizing

  @Test func safeRemoteDiagnosticPassesPlainTextThrough() {
    // given
    let remote = "authorization pending"

    // when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [], maxBytes: 200)

    // then
    #expect(safe == remote)
  }

  @Test(arguments: [
    ("line one\nline two", "line one line two"),
    ("tab\tseparated", "tab separated"),
    ("many     spaces", "many spaces"),
    ("mixed \t\n\r whitespace", "mixed whitespace"),
    ("  surrounded  ", "surrounded"),
    ("\n\n", ""),
  ])
  func safeRemoteDiagnosticCollapsesWhitespaceRunsToSingleSpaces(
    remote: String,
    expected: String
  ) {
    // given / when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [], maxBytes: 200)

    // then
    #expect(safe == expected)
  }

  @Test(arguments: [
    // A CSI sequence: colouring stderr from a remote body.
    ("\u{1B}[31mdenied\u{1B}[0m", "denied"),
    // A screen-clear that would erase preceding terminal output.
    ("gone\u{1B}[2J", "gone"),
    // An OSC sequence terminated by BEL, which can retitle the operator's window.
    ("\u{1B}]0;pwned\u{7}title", "title"),
    // The same OSC terminated by ST rather than BEL.
    ("\u{1B}]0;pwned\u{1B}\\rest", "rest"),
    // A bare two-character escape.
    ("\u{1B}7saved", "saved"),
    // The C1 CSI introducer, an escape that carries no ESC byte at all.
    ("\u{9B}31mred", "red"),
    // A lone control that is not part of any sequence.
    ("bell\u{7}rung", "bellrung"),
    ("nul\u{0}separated", "nulseparated"),
  ])
  func safeRemoteDiagnosticStripsTerminalEscapesAndControls(remote: String, expected: String) {
    // given / when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [], maxBytes: 200)

    // then
    #expect(safe == expected)
    #expect(safe.unicodeScalars.contains("\u{1B}") == false)
  }

  // MARK: - Safe Remote Diagnostic: Redaction

  @Test func safeRemoteDiagnosticRedactsExactTokenValues() {
    // given
    let token = "sk-live-abcdef123456"
    let remote = "rejected token \(token) for account"

    // when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [token], maxBytes: 200)

    // then
    #expect(safe.contains(token) == false)
    #expect(safe == "rejected token \(SecretRedactor.replacement) for account")
  }

  @Test func safeRemoteDiagnosticRedactsEveryValueInTheSetAndEveryOccurrence() {
    // given
    let access = "access-token-value"
    let refresh = "refresh-token-value"
    let remote = "\(access) then \(refresh) then \(access) again"

    // when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(
      remote,
      redacting: [access, refresh],
      maxBytes: 400
    )

    // then
    #expect(safe.contains(access) == false)
    #expect(safe.contains(refresh) == false)
    #expect(safe.contains(SecretRedactor.replacement))
  }

  @Test func safeRemoteDiagnosticRedactsATokenThatEscapesSplitInTheRemoteText() {
    // given
    // A server echoing our token with an escape wedged into it would defeat a redactor that
    // scrubbed before sanitizing: stripping the escape afterwards would reassemble the secret.
    let token = "secret-token-value"
    let remote = "echo sec\u{1B}[0mret-token-value done"

    // when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [token], maxBytes: 200)

    // then
    #expect(safe.contains(token) == false)
    #expect(safe == "echo \(SecretRedactor.replacement) done")
  }

  @Test func safeRemoteDiagnosticRedactsATokenSplitByWhitespaceCollapse() {
    // given
    let token = "account id 42"
    let remote = "header\naccount\t\tid   42\nend"

    // when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [token], maxBytes: 200)

    // then
    #expect(safe == "header \(SecretRedactor.replacement) end")
  }

  @Test func safeRemoteDiagnosticIgnoresEmptyRedactionValues() {
    // given
    let remote = "plain text"

    // when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [""], maxBytes: 200)

    // then
    #expect(safe == remote)
  }

  // MARK: - Safe Remote Diagnostic: Bounding

  @Test func safeRemoteDiagnosticTruncatesToTheByteBound() {
    // given
    let remote = String(repeating: "a", count: 500)

    // when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [], maxBytes: 32)

    // then
    #expect(safe.utf8.count <= 32)
    #expect(safe.hasPrefix("aaaa"))
  }

  @Test func safeRemoteDiagnosticTruncatesOnAScalarBoundary() {
    // given
    // Each "é" is two UTF-8 bytes, so an odd cap lands mid-scalar unless truncation is boundary-safe.
    let remote = String(repeating: "é", count: 20)

    // when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [], maxBytes: 7)

    // then
    #expect(safe.utf8.count <= 7)
    #expect(safe == "ééé")
  }

  @Test func safeRemoteDiagnosticRedactsBeforeItTruncatesSoNoTokenSurvivesInThePrefix() {
    // given
    let token = "leading-secret"
    let remote = "\(token) then a very long tail \(String(repeating: "z", count: 400))"

    // when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [token], maxBytes: 64)

    // then
    #expect(safe.contains(token) == false)
    #expect(safe.hasPrefix(SecretRedactor.replacement))
    #expect(safe.utf8.count <= 64)
  }

  @Test func safeRemoteDiagnosticReturnsEmptyForAWhollyUnprintableBody() {
    // given
    let remote = "\u{1B}[31m\u{0}\u{7}\u{1B}[0m"

    // when
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(remote, redacting: [], maxBytes: 200)

    // then
    #expect(safe.isEmpty)
  }
}
