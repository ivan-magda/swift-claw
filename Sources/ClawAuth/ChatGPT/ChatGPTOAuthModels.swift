import Foundation

// MARK: - Device Authorization

/// What the vendor hands back when a device asks to be authorized: the identifier the poll quotes,
/// the code the owner types, and how often the vendor is willing to be asked.
public struct ChatGPTDeviceCode: Sendable, Equatable {
  /// The device's identity for the poll. It is a bearer of the pending authorization — anyone
  /// holding it can claim the grant the owner is about to approve — so it belongs on the wire and
  /// nowhere else.
  public let deviceAuthID: String
  public let userCode: String
  public let pollInterval: Duration

  public init(deviceAuthID: String, userCode: String, pollInterval: Duration) {
    self.deviceAuthID = deviceAuthID
    self.userCode = userCode
    self.pollInterval = pollInterval
  }
}

/// Neither form prints the device-auth ID. The default mirror would, and this value passes through
/// log lines and error interpolation on a path whose whole point is that the owner sees the user
/// code and nothing else.
extension ChatGPTDeviceCode: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "ChatGPTDeviceCode(userCode: \(userCode), pollInterval: \(pollInterval))"
  }

  public var debugDescription: String {
    description
  }
}

/// The proof of approval a device poll returns, spendable exactly once at the token endpoint.
public struct ChatGPTAuthorizationGrant: Sendable, Equatable {
  public let authorizationCode: String
  public let codeVerifier: String

  public init(authorizationCode: String, codeVerifier: String) {
    self.authorizationCode = authorizationCode
    self.codeVerifier = codeVerifier
  }
}

/// A validated credential pair. Reaching this type means the tokens are already bounded and fit for
/// a header, and the expiry is a real instant in the future — a caller may spend it without
/// re-deciding any of that.
public struct ChatGPTTokenPair: Sendable, Equatable {
  public let accessToken: String
  /// Absent when a refresh response rotated no new token, which means the caller's existing one
  /// stands. It never means "the vendor took the refresh token away".
  public let refreshToken: String?
  public let expiresAt: Date

  public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
}

/// What one poll learned. Pending and throttled are outcomes rather than errors: both mean the flow
/// is healthy and the answer is "not yet".
public enum ChatGPTPollResult: Sendable, Equatable {
  case pending
  case throttled(retryAfter: Duration)
  case granted(ChatGPTAuthorizationGrant)
}

// MARK: - Failures

/// Why an OAuth call could not produce what it was asked for. Every case is safe to show an owner:
/// remote text has already been sanitized, bounded, and redacted before it reaches a `detail`.
///
/// The distinction the cases exist to draw is what a caller may do next — retry, wait, or log in
/// again — not what the vendor's status line happened to say.
public enum ChatGPTOAuthFailure: Error, Sendable, Equatable {
  /// The vendor asked to be left alone for a while. `retryAfter` is absent when it named no usable
  /// delay, which leaves the wait to the caller's own policy rather than inventing one here.
  case throttled(retryAfter: Duration?)
  /// The vendor answered with something this flow cannot use. Retrying an identical request would
  /// produce an identical answer.
  case malformedResponse(detail: String)
  /// The credential itself is finished: expired, revoked, already spent, or never valid. Only a new
  /// login repairs this, and no amount of retrying will.
  case grantRejected(detail: String)
  /// The attempt did not complete for a reason that may not recur — the network, or the vendor
  /// having a bad minute. Worth retrying under a budget.
  case transport(detail: String)
  /// The login window the owner was promised has closed.
  case deadlineExceeded
}

// MARK: - Seams

/// The refresh half of the token endpoint, named separately so the credential source can depend on
/// the one call it makes rather than on the whole login flow.
public protocol ChatGPTOAuthRefreshing: Sendable {
  func refresh(
    refreshToken: String,
    timeout: Duration
  ) async throws -> ChatGPTTokenPair
}

public protocol ChatGPTOAuthExchanging: Sendable {
  func exchange(
    grant: ChatGPTAuthorizationGrant,
    timeout: Duration
  ) async throws -> ChatGPTTokenPair
}
