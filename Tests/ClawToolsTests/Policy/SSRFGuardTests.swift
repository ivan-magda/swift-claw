import ClawCore
import Foundation
import Testing

@testable import ClawTools

@Suite struct SSRFGuardTests {
  // FR-T8's pinned refusal table — every row here is an address web_fetch must refuse.
  private static let blockedAddresses: [String] = [
    // loopback
    "127.0.0.1", "127.8.8.8", "::1",
    // RFC-1918
    "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.1.1",
    // link-local (incl. the cloud metadata endpoint) and v6 link-local
    "169.254.0.1", "169.254.169.254", "fe80::1", "febf::1",
    // CGNAT
    "100.64.0.1", "100.127.255.254",
    // ULA
    "fc00::1", "fdff::1",
    // unspecified
    "0.0.0.0", "::",
    // multicast / broadcast
    "224.0.0.1", "239.255.255.255", "255.255.255.255", "ff02::1",
    // reserved / documentation
    "192.0.2.1", "198.51.100.7", "203.0.113.9", "198.18.0.1", "240.0.0.1", "2001:db8::1",
    // IPv4-mapped IPv6 wrapping a private address (unwrapped and re-checked)
    "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:192.168.0.1", "::ffff:169.254.169.254",
    // NAT64 (64:ff9b::/96) wrapping loopback / the cloud-metadata endpoint
    "64:ff9b::7f00:1", "64:ff9b::a9fe:a9fe",
    // IPv4-compatible ::a.b.c.d (deprecated) wrapping loopback / a private address
    "::127.0.0.1", "::10.0.0.1",
  ]

  private static let publicAddresses: [String] = [
    "93.184.216.34",  // example.com
    "8.8.8.8",
    "1.1.1.1",
    "172.15.0.1",  // just below RFC-1918 172.16/12
    "172.32.0.1",  // just above it
    "100.63.255.255",  // just below CGNAT
    "100.128.0.0",  // just above it
    "9.255.255.255",  // just below 10/8
    "11.0.0.0",  // just above it
    "2606:2800:220:1:248:1893:25c8:1946",  // example.com v6
    "::ffff:8.8.8.8",  // mapped PUBLIC v4 is fine
    "64:ff9b::808:808",  // NAT64 wrapping a PUBLIC v4 (8.8.8.8) must still be allowed
  ]

  @Test(arguments: blockedAddresses)
  func refusesNonPublicAddress(_ text: String) throws {
    // given
    let address = try #require(ResolvedAddress.parse(text), "unparseable fixture: \(text)")

    // when / then
    #expect(SSRFGuard.isPublic(address) == false, "\(text) must be refused")
  }

  @Test(arguments: publicAddresses)
  func allowsPublicAddress(_ text: String) throws {
    // given
    let address = try #require(ResolvedAddress.parse(text), "unparseable fixture: \(text)")

    // when / then
    #expect(SSRFGuard.isPublic(address), "\(text) must be allowed")
  }

  @Test func benchmarkRangeMatchesTheBlocklistBenchmarkingRow() throws {
    // given — the pinned handle the fake-IP relaxation and doctor key on
    let range = SSRFGuard.benchmarkRange

    // when / then — its bounds agree with what the blocklist refuses
    let firstAddress = try #require(ResolvedAddress.parse("198.18.0.0"))
    let lastAddress = try #require(ResolvedAddress.parse("198.19.255.255"))
    let belowAddress = try #require(ResolvedAddress.parse("198.17.255.255"))
    let aboveAddress = try #require(ResolvedAddress.parse("198.20.0.0"))
    #expect(range.contains(firstAddress) && SSRFGuard.isPublic(firstAddress) == false)
    #expect(range.contains(lastAddress) && SSRFGuard.isPublic(lastAddress) == false)
    #expect(range.contains(belowAddress) == false)
    #expect(range.contains(aboveAddress) == false)
  }

  @Test func parseRejectsGarbage() {
    // given / when / then
    #expect(ResolvedAddress.parse("not-an-ip") == nil)
    #expect(ResolvedAddress.parse("999.1.1.1") == nil)
    #expect(ResolvedAddress.parse("") == nil)
  }

  @Test func systemResolverResolvesLoopbackName() async throws {
    // given — "localhost" resolves without the network; pins the getaddrinfo plumbing
    let resolver = SystemAddressResolver()

    // when
    let addresses = try await resolver.resolve(host: "localhost")

    // then
    #expect(addresses.isEmpty == false)
    #expect(addresses.allSatisfy { address in SSRFGuard.isPublic(address) == false })
  }

  @Test func systemResolverShortCircuitsLiteralsWithoutDNS() async throws {
    // given
    let resolver = SystemAddressResolver()

    // when
    let addresses = try await resolver.resolve(host: "127.0.0.1")

    // then — a literal parses locally; it must never hit the resolver
    #expect(addresses == [ResolvedAddress.parse("127.0.0.1")])
  }
}
