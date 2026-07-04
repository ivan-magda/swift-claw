import Foundation
import Testing

@testable import ClawTools

@Suite struct CanonicalURLTests {
  private func canonical(_ raw: String) -> String? {
    if case .success(let value) = CanonicalURL.canonicalize(raw) {
      return value
    }
    return nil
  }

  private func failure(_ raw: String) -> CanonicalURLError? {
    if case .failure(let error) = CanonicalURL.canonicalize(raw) {
      return error
    }
    return nil
  }

  @Test func lowercasesSchemeAndHostAndStripsDefaultPort() {
    // given / when / then
    #expect(canonical("HTTPS://Example.COM/path") == "https://example.com/path")
    #expect(canonical("https://example.com:443/a") == "https://example.com/a")
    #expect(canonical("http://example.com:80/a") == "http://example.com/a")
  }

  @Test func emptyPathBecomesSlash() {
    // given / when / then
    #expect(canonical("https://example.com") == "https://example.com/")
  }

  @Test func queryIsPreservedByteForByte() {
    // given — the query is where an exfil payload lives (FR-T5/T6)
    let raw = "https://example.com/a?q=hello+world&token=abc%2Fdef&&x==y"

    // when / then — only escape-hex uppercasing may change it
    #expect(canonical(raw) == "https://example.com/a?q=hello+world&token=abc%2Fdef&&x==y")
  }

  @Test func onePercentNormalizationPassUppercasesEscapeHex() {
    // given / when / then — %2f → %2F, but nothing is decoded
    #expect(canonical("https://example.com/a%2fb?x=%3d") == "https://example.com/a%2Fb?x=%3D")
  }

  @Test func fragmentIsStripped() {
    // given / when / then
    #expect(canonical("https://example.com/a?q=1#section") == "https://example.com/a?q=1")
  }

  @Test func grantMatchIsExactOnQueryBytes() {
    // given — any query-byte difference must produce a different canonical form
    let first = canonical("https://example.com/a?q=1")
    let second = canonical("https://example.com/a?q=2")

    // then
    #expect(first != nil)
    #expect(first != second)
  }

  @Test func refusesIDNAndPunycodeHosts() {
    // given / when / then (rev.1 M2 — no homograph judgment in v1)
    #expect(failure("https://exämple.com/") == .nonASCIIHost)
    #expect(failure("https://xn--e1afmkfd.xn--p1ai/") == .nonASCIIHost)
    // URLComponents surfaces this host as nil (the label check is never reached), so canonicalize
    // returns .unparseable here rather than .nonASCIIHost — either refusal is correct.
    #expect([.nonASCIIHost, .unparseable].contains(failure("https://sub.XN--fake.example/")))
  }

  @Test func refusesUserinfoAtCanonicalizationTime() {
    // given / when / then — before any approval prompt is built (§9.2)
    #expect(failure("https://user:pass@example.com/") == .userinfoPresent)
    #expect(failure("https://user@example.com/") == .userinfoPresent)
  }

  @Test func refusesNonAllowlistedSchemesAndPorts() {
    // given / when / then
    #expect(failure("ftp://example.com/") == .unsupportedScheme("ftp"))
    #expect(failure("file:///etc/passwd") == .unsupportedScheme("file"))
    #expect(failure("https://example.com:8443/") == .unsupportedPort(8443))
    // 80/443 allowed explicitly
    #expect(canonical("https://example.com:80/a") == "https://example.com:80/a")
  }

  @Test func refusesGarbage() {
    // given / when / then
    #expect(failure("not a url") != nil)
    #expect(failure("") != nil)
    #expect(failure("https://") != nil)
  }
}
