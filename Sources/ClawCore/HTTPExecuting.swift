import Foundation

/// The raw HTTP send, abstracted so each client's parsing/error-mapping is testable without the
/// network. Lives in `ClawCore` (no NIO) so both `ClawTelegram` and `ClawLLM` share one seam.
public struct HTTPResult: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String], body: Data) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }

  /// HTTP header names are case-insensitive; callers (cost / Retry-After) must not depend on casing.
  public func header(_ name: String) -> String? {
    let wanted = name.lowercased()
    return headers.first { $0.key.lowercased() == wanted }?.value
  }
}

public protocol HTTPExecuting: Sendable {
  /// `headers` carries request headers (Telegram passes `[:]` — its token is in the URL path;
  /// the LLM client passes `Authorization: Bearer …`).
  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult
}
