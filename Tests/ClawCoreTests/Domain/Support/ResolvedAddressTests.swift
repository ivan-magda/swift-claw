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
}
