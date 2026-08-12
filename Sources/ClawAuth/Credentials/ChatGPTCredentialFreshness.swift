import ClawCore
import Foundation

/// How much life a stored access token has left, judged against a supplied wall date.
///
/// This is the only place the skew window is applied. Status, the runtime credential source, and
/// doctor all classify through it, so an owner cannot be told a token is fresh while the source
/// that will actually use it decides otherwise.
public enum ChatGPTCredentialFreshness: Sendable, Equatable {
  /// Usable as it stands.
  case fresh
  /// Still valid, but close enough to lapsing that a request should refresh before spending it.
  case expiring
  /// Past its expiry. A refresh token may still redeem it, so this is not "logged out".
  case expired

  /// Judges against `now` rather than the process clock: the callers each supply their own wall
  /// date, which is what lets one rule serve a live daemon and a status read alike.
  public static func classify(expiresAt: Date, now: Date) -> ChatGPTCredentialFreshness {
    guard expiresAt > now else {
      return .expired
    }
    let skew = TimeInterval(ChatGPTProviderMetadata.credentialFreshnessSkew.components.seconds)
    return expiresAt > now.addingTimeInterval(skew) ? .fresh : .expiring
  }
}
