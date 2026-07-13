import Foundation

public struct HTTPResult: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String], body: Data) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }

  public func getHeader(for name: String) -> String? {
    headers.caseInsensitiveValue(for: name)
  }
}

public struct HTTPStreamHead: Sendable, Equatable {
  public let statusCode: Int
  public let headers: [String: String]

  public init(statusCode: Int, headers: [String: String]) {
    self.statusCode = statusCode
    self.headers = headers
  }

  public func getHeader(for name: String) -> String? {
    headers.caseInsensitiveValue(for: name)
  }
}

private extension Dictionary where Key == String, Value == String {
  /// Case-insensitive header lookup: HTTP field names are case-insensitive, but the header maps
  /// preserve the wire casing, so match on a lowercased key.
  func caseInsensitiveValue(for key: String) -> String? {
    let target = key.lowercased()
    return first { $0.key.lowercased() == target }?.value
  }
}

public protocol HTTPExecuting: Sendable {
  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult

  /// Plain GET for tool fetches. The production client is configured with
  /// `RedirectConfiguration.disallow`, so a 3xx comes back as an ordinary `HTTPResult`; the body
  /// is collected up to `maxBodyBytes` and an over-cap response throws.
  func get(
    url: String,
    headers: [String: String],
    timeoutSeconds: Int,
    maxBodyBytes: Int
  ) async throws -> HTTPResult
}

public protocol HTTPStreaming: Sendable {
  func postStream(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> (head: HTTPStreamHead, body: AsyncThrowingStream<Data, Error>)
}
