import ClawCore
import Foundation
import Testing

@Suite struct CIDRTests {
  @Test func parsesIPv4Network() throws {
    // given / when
    let cidr = try #require(CIDR.parse("198.18.0.0/15"))

    // then
    #expect(cidr.network == ResolvedAddress.parse("198.18.0.0"))
    #expect(cidr.prefixLength == 15)
  }

  @Test func parsesIPv6Network() throws {
    // given / when
    let cidr = try #require(CIDR.parse("fc00::/18"))

    // then
    #expect(cidr.network == ResolvedAddress.parse("fc00::"))
    #expect(cidr.prefixLength == 18)
  }

  @Test func parseNormalizesHostBitsToTheNetworkAddress() throws {
    // given — a sloppy entry naming a host inside the block, not the block itself
    let cidr = try #require(CIDR.parse("198.18.0.84/15"))

    // then
    #expect(cidr == CIDR.parse("198.18.0.0/15"))
  }

  @Test(arguments: [
    "", "not-a-cidr", "198.18.0.0", "198.18.0.0/", "/15", "198.18.0.0/33", "198.18.0.0/-1",
    "198.18.0.0/1.5", "fc00::/129", "198.18.0.0/15/24", "999.1.1.1/8", "198.18.0.0/ 15",
  ])
  func parseRejectsMalformedInput(_ text: String) {
    // given / when / then
    #expect(CIDR.parse(text) == nil, "\(text) must not parse")
  }

  @Test(arguments: ["198.18.0.0", "198.18.0.84", "198.19.255.255"])
  func containsAddressesInsideTheIPv4Block(_ text: String) throws {
    // given
    let cidr = try #require(CIDR.parse("198.18.0.0/15"))
    let address = try #require(ResolvedAddress.parse(text))

    // when / then
    #expect(cidr.contains(address), "\(text) must be inside 198.18.0.0/15")
  }

  @Test(arguments: ["198.17.255.255", "198.20.0.0", "10.0.0.1", "8.8.8.8"])
  func excludesAddressesOutsideTheIPv4Block(_ text: String) throws {
    // given
    let cidr = try #require(CIDR.parse("198.18.0.0/15"))
    let address = try #require(ResolvedAddress.parse(text))

    // when / then
    #expect(cidr.contains(address) == false, "\(text) must be outside 198.18.0.0/15")
  }

  @Test func singleHostPrefixMatchesOnlyThatAddress() throws {
    // given
    let cidr = try #require(CIDR.parse("10.8.0.1/32"))

    // when / then
    #expect(cidr.contains(try #require(ResolvedAddress.parse("10.8.0.1"))))
    #expect(cidr.contains(try #require(ResolvedAddress.parse("10.8.0.2"))) == false)
  }

  @Test func zeroPrefixMatchesEveryAddressOfTheFamily() throws {
    // given
    let cidr = try #require(CIDR.parse("0.0.0.0/0"))

    // when / then
    #expect(cidr.contains(try #require(ResolvedAddress.parse("8.8.8.8"))))
    #expect(cidr.contains(try #require(ResolvedAddress.parse("255.255.255.255"))))
  }

  @Test func containsRespectsIPv6PrefixBitsMidByte() throws {
    // given — /18 splits inside the third byte: its top two bits must be 00
    let cidr = try #require(CIDR.parse("fc00::/18"))

    // when / then
    #expect(cidr.contains(try #require(ResolvedAddress.parse("fc00::1"))))
    #expect(cidr.contains(try #require(ResolvedAddress.parse("fc00:3f00::1"))))
    #expect(cidr.contains(try #require(ResolvedAddress.parse("fc00:4000::1"))) == false)
  }

  @Test func containsIsStrictAboutAddressFamily() throws {
    // given — an IPv4-mapped IPv6 form of an in-range v4 address
    let v4Block = try #require(CIDR.parse("198.18.0.0/15"))
    let v6Block = try #require(CIDR.parse("fc00::/18"))

    // when / then — no cross-family or mapped-form matching; a mapped form that slips the
    // exemption fails CLOSED (the fetch is refused), never open
    #expect(v4Block.contains(try #require(ResolvedAddress.parse("::ffff:198.18.0.84"))) == false)
    #expect(v6Block.contains(try #require(ResolvedAddress.parse("198.18.0.84"))) == false)
  }

  @Test func rendersCanonicalCIDRNotation() throws {
    // given / when / then — doctor rows and refusal copy print the normalized block
    #expect("\(try #require(CIDR.parse("198.18.0.84/15")))" == "198.18.0.0/15")
    #expect("\(try #require(CIDR.parse("fc00::/18")))" == "fc00::/18")
  }
}
