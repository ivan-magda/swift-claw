import Foundation
import Testing

@testable import ClawAuth

@Suite struct ChatGPTCredentialFreshnessTests {
  /// An arbitrary fixed wall date. Classification is relative, so the absolute instant is
  /// immaterial — but it must not be `Date()`, or the boundary cases would race the clock.
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  // MARK: - Classification

  @Test(arguments: [
    // Beyond the skew: usable without refresh.
    (121.0, ChatGPTCredentialFreshness.fresh),
    (300.0, ChatGPTCredentialFreshness.fresh),
    (86_400.0, ChatGPTCredentialFreshness.fresh),
    // Inside the skew but not yet past: still valid, refresh on use.
    (120.0, ChatGPTCredentialFreshness.expiring),
    (119.0, ChatGPTCredentialFreshness.expiring),
    (1.0, ChatGPTCredentialFreshness.expiring),
    // At or past the expiry instant.
    (0.0, ChatGPTCredentialFreshness.expired),
    (-1.0, ChatGPTCredentialFreshness.expired),
    (-86_400.0, ChatGPTCredentialFreshness.expired),
  ])
  func classifyPartitionsTheSkewWindow(
    secondsUntilExpiry: TimeInterval,
    expected: ChatGPTCredentialFreshness
  ) {
    // given
    let expiresAt = Self.now.addingTimeInterval(secondsUntilExpiry)

    // when
    let freshness = ChatGPTCredentialFreshness.classify(expiresAt: expiresAt, now: Self.now)

    // then
    #expect(freshness == expected)
  }

  // MARK: - Skew Boundary

  @Test func aTokenIsFreshOnlyStrictlyBeyondTheSkew() {
    // given
    // The rule is `expiresAt > now + skew`, so the instant exactly on the skew is not fresh.
    let onTheSkew = Self.now.addingTimeInterval(120)
    let justBeyond = Self.now.addingTimeInterval(120.001)

    // when / then
    #expect(ChatGPTCredentialFreshness.classify(expiresAt: onTheSkew, now: Self.now) == .expiring)
    #expect(ChatGPTCredentialFreshness.classify(expiresAt: justBeyond, now: Self.now) == .fresh)
  }

  @Test func aTokenIsExpiredAtItsExpiryInstantRatherThanAfterIt() {
    // given
    let atExpiry = Self.now
    let justBefore = Self.now.addingTimeInterval(-0.001)
    let justAfter = Self.now.addingTimeInterval(0.001)

    // when / then
    #expect(ChatGPTCredentialFreshness.classify(expiresAt: atExpiry, now: Self.now) == .expired)
    #expect(ChatGPTCredentialFreshness.classify(expiresAt: justBefore, now: Self.now) == .expired)
    #expect(ChatGPTCredentialFreshness.classify(expiresAt: justAfter, now: Self.now) == .expiring)
  }

  // MARK: - Pinned Skew

  @Test func theSkewIsThePinned120Seconds() {
    // given / when / then
    #expect(ChatGPTProviderMetadata.credentialFreshnessSkew == .seconds(120))
  }

  @Test func classifyReadsTheSkewFromTheProviderMetadataRatherThanASecondCopy() {
    // given
    // Derives the boundary from the pinned skew, so widening the constant without widening the
    // classifier — or vice versa — fails here rather than silently splitting the two.
    let skew = TimeInterval(ChatGPTProviderMetadata.credentialFreshnessSkew.components.seconds)
    let onTheSkew = Self.now.addingTimeInterval(skew)
    let beyondTheSkew = Self.now.addingTimeInterval(skew + 1)

    // when / then
    #expect(ChatGPTCredentialFreshness.classify(expiresAt: onTheSkew, now: Self.now) == .expiring)
    #expect(ChatGPTCredentialFreshness.classify(expiresAt: beyondTheSkew, now: Self.now) == .fresh)
  }

  // MARK: - Wall-Date Independence

  @Test func classificationFollowsTheSuppliedWallDateNotTheProcessClock() {
    // given
    // A credential that expired long ago in real time is fresh against a `now` that precedes it,
    // which is what lets status, refresh, and doctor share one classifier under an injected date.
    let expiresAt = Date(timeIntervalSince1970: 1_000_000_000)
    let earlier = expiresAt.addingTimeInterval(-3_600)

    // when / then
    #expect(ChatGPTCredentialFreshness.classify(expiresAt: expiresAt, now: earlier) == .fresh)
    #expect(ChatGPTCredentialFreshness.classify(expiresAt: expiresAt, now: Date()) == .expired)
  }
}
