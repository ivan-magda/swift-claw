import Foundation

/// Drives a device authorization from the first request to an approved grant.
///
/// It owns the login window and every wait inside it, which is what lets the wire client stay a
/// stateless one-call-at-a-time seam with no notion of time at all. Two clocks meet here and stay
/// apart: this type's monotonic clock, which cannot be moved by an owner correcting their system
/// time mid-login, measures the window and the waits; the wall date the client was built with
/// measures a token's expiry, which is a date the vendor and the daemon must agree on.
///
/// Generic over the clock so the fifteen-minute window can be driven to its end without waiting out
/// fifteen minutes, and without a double having to fabricate a `ContinuousClock.Instant`.
public struct ChatGPTDeviceAuthorization<ClockType: Clock>: Sendable
where ClockType.Duration == Duration {
  private let client: ChatGPTOAuthClient
  private let clock: ClockType

  public init(client: ChatGPTOAuthClient, clock: ClockType) {
    self.client = client
    self.clock = clock
  }

  /// Asks for a device code, reports it, then waits for the owner to approve it.
  ///
  /// `onDeviceCode` runs before the first poll: the owner cannot approve a code they have not been
  /// shown, so every second spent polling before then is a second of their window spent on nothing.
  ///
  /// - Throws: `ChatGPTOAuthFailure.deadlineExceeded` once the window closes, the wire client's
  ///   typed failure for a terminal answer, or `CancellationError` if the owner walks away.
  public func authorize(
    onDeviceCode: @escaping @Sendable (ChatGPTDeviceCode) async -> Void
  ) async throws -> ChatGPTAuthorizationGrant {
    let deadline = clock.now.advanced(by: ChatGPTProviderMetadata.maximumLoginWait)

    let opening = try requestTimeout(until: deadline)
    let device = try await client.requestDeviceCode(timeout: opening)
    await onDeviceCode(device)

    while true {
      let timeout = try requestTimeout(until: deadline)
      switch try await client.pollOnce(device: device, timeout: timeout) {
      case .granted(let grant):
        return grant
      case .pending:
        try await wait(device.pollInterval, until: deadline)
      case .throttled(let retryAfter):
        try await wait(retryAfter, until: deadline)
      }
    }
  }
}

/// The device flow as the login sequence depends on it: one call, one grant. `authorize` above
/// already is that call, so the conformance adds no behavior — it only lets a caller name the
/// outcome it needs without also naming the clock the poll loop is generic over.
extension ChatGPTDeviceAuthorization: ChatGPTDeviceAuthorizing {}

// MARK: - The Login Window

private extension ChatGPTDeviceAuthorization {
  /// What is left of the window — and the end of the login the moment nothing is.
  func remaining(until deadline: ClockType.Instant) throws -> Duration {
    let left = clock.now.duration(to: deadline)
    guard left > .zero else {
      throw ChatGPTOAuthFailure.deadlineExceeded
    }
    return left
  }

  /// A ceiling on the call, cut down to whatever is left of the window. Without the second cut, one
  /// stalled request could run past the deadline the owner was quoted and leave the flow reporting a
  /// failure minutes after it promised an answer.
  func requestTimeout(until deadline: ClockType.Instant) throws -> Duration {
    let left = try remaining(until: deadline)
    return min(ChatGPTProviderMetadata.requestTimeout, left)
  }

  /// Waits what was asked for — never less than the provider's floor, and never past the window.
  /// Sleeping out the remainder rather than giving up early is what keeps the promise exact: the
  /// window is what the owner was told they had, and the next deadline check ends the login.
  func wait(_ requested: Duration, until deadline: ClockType.Instant) async throws {
    let left = try remaining(until: deadline)
    let delay = min(ChatGPTProviderMetadata.honoredPollDelay(requested), left)
    try await clock.sleep(for: delay)
  }
}
