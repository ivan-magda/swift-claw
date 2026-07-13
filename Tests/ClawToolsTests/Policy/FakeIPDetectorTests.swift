import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawTools

@Suite struct FakeIPDetectorTests {
  private let poolAddressOne: ResolvedAddress
  private let poolAddressTwo: ResolvedAddress
  private let poolAddressThree: ResolvedAddress
  private let publicAddress: ResolvedAddress

  init() throws {
    poolAddressOne = try #require(ResolvedAddress.parse("198.18.0.84"))
    poolAddressTwo = try #require(ResolvedAddress.parse("198.18.0.85"))
    poolAddressThree = try #require(ResolvedAddress.parse("198.19.255.1"))
    publicAddress = try #require(ResolvedAddress.parse("93.184.216.34"))
  }

  /// Fixed canary hosts and a fixed "nonexistent" host so the scripted table can address them.
  private func makeDetector(table: [String: [ResolvedAddress]]) -> FakeIPDetector {
    FakeIPDetector(
      resolver: ScriptedResolver(table: table),
      publicCanaryHosts: ["canary-one.example", "canary-two.example"],
      makeNonexistentHost: { "never-registered.example" }
    )
  }

  @Test func allCanariesCollapsingIntoTheBenchmarkRangeConfirmsFakeIP() async {
    // given — public canaries AND the nonexistent host all answer from the pool
    let detector = makeDetector(table: [
      "canary-one.example": [poolAddressOne],
      "canary-two.example": [poolAddressTwo],
      "never-registered.example": [poolAddressThree],
    ])

    // when / then
    #expect(await detector.detect() == .active(sample: poolAddressOne))
  }

  @Test func realDNSAnswersMeanInactive() async {
    // given — canaries resolve to genuine public addresses; the nonexistent host NXDOMAINs
    // (absent from the table, so the scripted resolver throws)
    let detector = makeDetector(table: [
      "canary-one.example": [publicAddress],
      "canary-two.example": [publicAddress],
    ])

    // when / then
    #expect(await detector.detect() == .inactive)
  }

  @Test func nxdomainForTheNonexistentHostMeansInactive() async {
    // given — publics land in the pool but the nonexistent host NXDOMAINs: whatever rewrote the
    // publics is not fabricating answers, so it is not confirmed fake-IP interception
    let detector = makeDetector(table: [
      "canary-one.example": [poolAddressOne],
      "canary-two.example": [poolAddressTwo],
    ])

    // when / then
    #expect(await detector.detect() == .inactive)
  }

  @Test func anyCanaryResolvingOutsideTheRangeMeansInactive() async {
    // given — a partially-filtered proxy (fake-ip-filter) answers one canary with a real address
    let detector = makeDetector(table: [
      "canary-one.example": [poolAddressOne],
      "canary-two.example": [publicAddress],
      "never-registered.example": [poolAddressThree],
    ])

    // when / then
    #expect(await detector.detect() == .inactive)
  }

  @Test func mixedAnswerForOneCanaryMeansInactive() async {
    // given — one canary answers with both a pool and a real address
    let detector = makeDetector(table: [
      "canary-one.example": [poolAddressOne, publicAddress],
      "canary-two.example": [poolAddressTwo],
      "never-registered.example": [poolAddressThree],
    ])

    // when / then
    #expect(await detector.detect() == .inactive)
  }

  @Test func emptyResolutionForACanaryMeansInactive() async {
    // given — a canary that resolves to zero addresses must not vacuously count as in-range
    let detector = makeDetector(table: [
      "canary-one.example": [],
      "canary-two.example": [poolAddressTwo],
      "never-registered.example": [poolAddressThree],
    ])

    // when / then
    #expect(await detector.detect() == .inactive)
  }
}
