import ClawCore
import Foundation
import Testing

@Suite struct ResolvedAddressTests {
  @Test(arguments: ["198.18.0.84", "10.0.0.5", "169.254.169.254", "2001:db8::1", "::1", "fe80::1"])
  func rendersParsedLiteralBackToText(_ text: String) throws {
    // given
    let address = try #require(ResolvedAddress.parse(text), "unparseable fixture: \(text)")

    // when / then — refusal copy prints the resolved address; the round-trip pins the
    // inet_ntop plumbing for both families
    #expect("\(address)" == text)
  }

  @Test(arguments: [
    // canonical literals
    "198.18.0.84", "10.0.0.5", "::1", "2001:db8::1",
    // legacy numeric IPv4 spellings getaddrinfo resolves without DNS
    "3323068500", "0xC6120054", "198.18.0.84", "198.18", "0300.0030.0000.0124",
  ])
  func denotesIPLiteralAcceptsEveryNumericHostForm(_ host: String) {
    // given / when / then — the classifier must catch the forms strict inet_pton misses, so a
    // legacy-spelled pool address cannot slip past the literal blocklist into a fake-IP widening
    #expect(ResolvedAddress.denotesIPLiteral(host: host), "\(host) must count as a literal")
  }

  @Test(arguments: ["example.com", "blog.jetbrains.com", "1password.com", "localhost", "a.b.c"])
  func denotesIPLiteralRejectsRealHostnames(_ host: String) {
    // given / when / then — DNS names (incl. digit-leading ones) are not literals; they resolve
    // through the resolver and remain eligible for the widenings
    #expect(ResolvedAddress.denotesIPLiteral(host: host) == false, "\(host) is not a literal")
  }
}
