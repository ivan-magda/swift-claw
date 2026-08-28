import AsyncHTTPClient
import Foundation

/// The egress posture for an AsyncHTTPClient-backed client.
public enum HTTPClientProfile: Sendable, Equatable {
  /// Bounds decompression while retaining the library's redirect-following default.
  case redirectFollowing
  /// Refuses redirects and bounds decompression; everything else, TLS included, stays at the
  /// library's default, which already verifies certificates in full. Restating that default here
  /// would only create a second place for it to be switched off.
  case protectedEgress

  /// The ceiling on a response body after it is inflated.
  public static let maximumDecompressedResponseBytes = 16 * 1024 * 1024

  /// The AsyncHTTPClient settings this posture resolves to.
  public var configuration: HTTPClient.Configuration {
    var configuration = HTTPClient.Configuration()
    configuration.decompression = .enabled(
      limit: .size(Self.maximumDecompressedResponseBytes)
    )

    if self == .protectedEgress {
      configuration.redirectConfiguration = .disallow
    }

    return configuration
  }
}
