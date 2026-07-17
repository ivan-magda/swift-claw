import AsyncHTTPClient
import Foundation

/// The egress posture for a client this daemon points at a third party.
///
/// It is a profile rather than a line at each call site because the two settings below are decided
/// per *client* in AsyncHTTPClient, not per request: whoever builds the client is the only code that
/// can make either choice, and a choice re-made at every construction site is one that will
/// eventually be made differently. Modelled as an `Equatable` case so a test can read a client's
/// role→profile mapping back — a bare `HTTPClient.Configuration` exposes no redirect posture it could
/// assert on.
public enum HTTPClientProfile: Sendable, Equatable {
  /// The Telegram transport's profile: bounded decompression, but redirects left at the library
  /// default. Telegram's Bot API answers a moved method with a redirect this client is expected to
  /// follow, and the token it carries is a bot token bound to Telegram's own hosts — not a bearer a
  /// redirect could walk onto a third party. Kept a named profile of its own so the redirect posture
  /// that separates it from `protectedEgress` is a deliberate choice rather than an omission.
  case telegram
  /// Refuses redirects and bounds decompression; everything else, TLS included, stays at the
  /// library's default, which already verifies certificates in full. Restating that default here
  /// would only create a second place for it to be switched off.
  ///
  /// Redirects are the setting that carries the weight. Following one lets the *response* choose
  /// where the next request goes, which would undo the thing every pinned provider URL here exists
  /// to hold: that the host answering a request is the host we picked. AsyncHTTPClient does drop
  /// `Authorization` when a redirect leaves the original origin, so a bearer does not ride a
  /// cross-origin hop — but it is kept on a same-origin one, and a request still leaves for
  /// somewhere nobody here chose. Refused, the redirect comes back as the answer it is, and a
  /// caller that genuinely wants the new location has to ask for it on purpose.
  case protectedEgress

  /// The ceiling on a response body after it is inflated. Decompression is a client-wide toggle —
  /// the executor only advertises `accept-encoding` — so without a limit here a few kilobytes of
  /// gzip can expand until the process is out of memory.
  public static let maximumDecompressedResponseBytes = 16 * 1024 * 1024

  /// The AsyncHTTPClient settings this posture resolves to. Decompression is bounded on both;
  /// `protectedEgress` additionally refuses redirects.
  public var configuration: HTTPClient.Configuration {
    var configuration = HTTPClient.Configuration()
    configuration.decompression = .enabled(limit: .size(Self.maximumDecompressedResponseBytes))
    if self == .protectedEgress {
      configuration.redirectConfiguration = .disallow
    }
    return configuration
  }
}
