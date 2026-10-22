import Foundation
import Testing

@testable import ClawAuth

@Suite
struct ChatGPTCredentialFreshnessTests {
  /// An arbitrary fixed wall date. Classification is relative, so the absolute instant is
  /// immaterial — but it must not be `Date()`, or the boundary cases would race the clock.
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  // MARK: - Classification

  /// The skew is 120 seconds and both comparisons are strict: `expiresAt > now + skew` is fresh and
  /// `expiresAt > now` is not yet expired. The sub-second rows are the only ones a whole-second
  /// truncation of either comparison would misfile.
  @Test(arguments: [
    // Beyond the skew: usable without refresh.
    (120.001, ChatGPTCredentialFreshness.fresh),
    (121.0, ChatGPTCredentialFreshness.fresh),
    (300.0, ChatGPTCredentialFreshness.fresh),
    (86_400.0, ChatGPTCredentialFreshness.fresh),
    // Inside the skew but not yet past: still valid, refresh on use.
    (120.0, ChatGPTCredentialFreshness.expiring),
    (119.0, ChatGPTCredentialFreshness.expiring),
    (1.0, ChatGPTCredentialFreshness.expiring),
    (0.001, ChatGPTCredentialFreshness.expiring),
    // At or past the expiry instant.
    (0.0, ChatGPTCredentialFreshness.expired),
    (-0.001, ChatGPTCredentialFreshness.expired),
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

  // MARK: - Wall-Date Independence

  @Test
  func classificationFollowsTheSuppliedWallDateNotTheProcessClock() {
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
