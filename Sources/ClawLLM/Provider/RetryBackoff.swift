import ClawCore
import Foundation

// MARK: - Retry backoff

/// The one retry-wait policy both wire adapters share: a capped full-jittered exponential window when
/// the server gave no hint, and a `Retry-After` hint honored only after it is clamped to the smaller
/// of the ceiling below and the configured request timeout.
///
/// The clamp lives here rather than in either adapter so neither route can honor an unbounded hint: a
/// `retry-after: 3600` (or a `retry-after-ms`) sleeps the same bounded wait on both. The clock is
/// injected, so a test drives every wait without real time passing.
struct RetryBackoff: Sendable {
  static let baseBackoffSeconds = 0.5
  static let maxBackoffSeconds = 30.0
  /// The ceiling a server `Retry-After` hint is clamped to before the request timeout clamps it
  /// further, and the wait a throttle names when it gives none.
  static let maximumRetryAfterSeconds = 30

  private let clock: any Clock<Duration>
  private let jitter: @Sendable (Duration) -> Duration
  private let requestTimeoutSeconds: Int

  init(
    clock: any Clock<Duration>,
    jitter: @escaping @Sendable (Duration) -> Duration,
    requestTimeoutSeconds: Int
  ) {
    self.clock = clock
    self.jitter = jitter
    self.requestTimeoutSeconds = requestTimeoutSeconds
  }

  /// Waits before the next attempt. A server `Retry-After` hint is honored once clamped; otherwise
  /// the delay grows exponentially from the base and is drawn under full jitter up to the cap.
  func wait(retryAfter: Duration?, attempt: Int) async throws {
    if let retryAfter {
      try await clock.sleep(for: clamped(retryAfter))
      return
    }
    let exponentialSeconds = Self.baseBackoffSeconds * pow(2, Double(attempt - 1))
    let capped = Duration.seconds(min(exponentialSeconds, Self.maxBackoffSeconds))
    try await clock.sleep(for: jitter(capped))
  }

  /// The bounded seconds a clean throttle surfaces to the owner, clamped the same way `wait` clamps a
  /// `Retry-After` hint so the number the owner is shown is the number that would actually be waited.
  func clampedRetryAfterSeconds(_ requested: Int?) -> Int? {
    guard let requested else {
      return nil
    }
    return min(requested, ceilingSeconds)
  }
}

// MARK: - Clamping

private extension RetryBackoff {
  /// The smaller of the fixed ceiling and the configured request timeout. The runtime's remaining
  /// turn deadline can still cancel a wait earlier than this.
  var ceilingSeconds: Int {
    min(Self.maximumRetryAfterSeconds, requestTimeoutSeconds)
  }

  func clamped(_ retryAfter: Duration) -> Duration {
    min(retryAfter, .seconds(ceilingSeconds))
  }
}
