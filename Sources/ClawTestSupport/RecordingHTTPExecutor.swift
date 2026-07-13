import ClawCore
import Foundation

/// One recorded outbound call, capturing the verb and the request fields tests assert over.
public struct RecordedHTTPRequest: Sendable, Equatable {
  public enum Method: Sendable, Equatable {
    case get
    case post
  }

  public let method: Method
  public let url: String
  public let headers: [String: String]
  public let body: Data?

  public init(method: Method, url: String, headers: [String: String], body: Data?) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }
}

/// A configurable `HTTPExecuting` double for tests: it answers each call from a URL-keyed response
/// map, falling back to an optional canned result, and records the URL, headers, and body of every
/// call so tests can assert what was (and was not) dispatched. A call that matches neither the map
/// nor a canned fallback throws, so an unexpected dispatch surfaces as a test failure.
public actor RecordingHTTPExecutor: HTTPExecuting {
  private let responses: [String: HTTPResult]
  private let cannedResult: HTTPResult?

  /// Every call in dispatch order, newest last.
  public private(set) var requests: [RecordedHTTPRequest] = []

  public init(responses: [String: HTTPResult] = [:], cannedResult: HTTPResult? = nil) {
    self.responses = responses
    self.cannedResult = cannedResult
  }

  public func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult {
    try record(method: .post, url: url, headers: headers, body: jsonBody)
  }

  public func get(
    url: String,
    headers: [String: String],
    timeoutSeconds: Int,
    maxBodyBytes: Int
  ) async throws -> HTTPResult {
    try record(method: .get, url: url, headers: headers, body: nil)
  }
}

// MARK: - Recorded fields

public extension RecordingHTTPExecutor {
  /// URLs of every recorded call, in dispatch order.
  var requestedURLs: [String] {
    requests.map(\.url)
  }

  /// Headers of every recorded call, in dispatch order.
  var requestedHeaders: [[String: String]] {
    requests.map(\.headers)
  }

  var lastURL: String? {
    requests.last?.url
  }

  var lastHeaders: [String: String] {
    requests.last?.headers ?? [:]
  }

  var lastBody: Data? {
    requests.last?.body
  }
}

// MARK: - Dispatch

private extension RecordingHTTPExecutor {
  struct UnscriptedRequest: Error {
    let url: String
  }

  func record(
    method: RecordedHTTPRequest.Method,
    url: String,
    headers: [String: String],
    body: Data?
  ) throws -> HTTPResult {
    requests.append(
      RecordedHTTPRequest(method: method, url: url, headers: headers, body: body)
    )
    if let scripted = responses[url] {
      return scripted
    }
    guard let cannedResult else {
      throw UnscriptedRequest(url: url)
    }
    return cannedResult
  }
}
