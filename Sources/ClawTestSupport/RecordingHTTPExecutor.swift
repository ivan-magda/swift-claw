import ClawCore
import Foundation

/// One recorded outbound call, capturing the request fields tests assert over.
public struct RecordedHTTPRequest: Sendable, Equatable {
  public let method: HTTPMethod
  public let url: String
  public let headers: [String: String]
  public let body: Data?
  public let timeoutSeconds: Int
  public let responseBodyPolicy: HTTPResponseBodyPolicy
  /// The cap the executor applied, picked from the policy by the scripted status. Tests assert on
  /// this when what matters is which of the two caps was in force, not the pair that was offered.
  public let selectedBodyCap: Int
  /// How many times this call's handoff ran. Exactly-once is the property the exposure ledger rests
  /// on, so the double counts it rather than assuming it.
  public let handoffCount: Int

  public init(
    method: HTTPMethod,
    url: String,
    headers: [String: String],
    body: Data?,
    timeoutSeconds: Int,
    responseBodyPolicy: HTTPResponseBodyPolicy,
    selectedBodyCap: Int,
    handoffCount: Int
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeoutSeconds = timeoutSeconds
    self.responseBodyPolicy = responseBodyPolicy
    self.selectedBodyCap = selectedBodyCap
    self.handoffCount = handoffCount
  }
}

/// A configurable `HTTPExecuting` double for tests: it answers each call from a URL-keyed response
/// map, falling back to an optional canned result, and records every call so tests can assert what
/// was (and was not) dispatched. A call that matches neither the map nor a canned fallback throws,
/// so an unexpected dispatch surfaces as a test failure.
///
/// It honours the seam's contract rather than shortcutting it: the body policy must be `.buffered`,
/// the handoff runs once before the scripted answer is produced, and a scripted body past the
/// applicable cap comes back truncated exactly as the real executor would deliver it.
public actor RecordingHTTPExecutor: HTTPExecuting {
  private let responses: [String: HTTPResult]
  private let cannedResult: HTTPResult?

  /// Every call this double received, in dispatch order, newest last.
  public private(set) var requests: [RecordedHTTPRequest] = []

  public init(responses: [String: HTTPResult] = [:], cannedResult: HTTPResult? = nil) {
    self.responses = responses
    self.cannedResult = cannedResult
  }

  public func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    guard case .buffered(let successBytes, let errorBytes) = request.responseBodyPolicy else {
      throw HTTPTransportFailure(
        disposition: .definitelyNotSent,
        safeMessage: "execute needs a buffered response body policy"
      )
    }

    let scripted = responses[request.url] ?? cannedResult
    let cap = (200..<300).contains(scripted?.statusCode ?? 0) ? successBytes : errorBytes
    var handoffCount = 0
    if let beginHandoff = request.beginHandoff {
      handoffCount = 1
      try beginHandoff()
    }
    requests.append(
      RecordedHTTPRequest(
        method: request.method,
        url: request.url,
        headers: request.headers,
        body: request.body,
        timeoutSeconds: request.timeoutSeconds,
        responseBodyPolicy: request.responseBodyPolicy,
        selectedBodyCap: cap,
        handoffCount: handoffCount
      )
    )

    guard let scripted else {
      throw UnscriptedRequest(url: request.url)
    }
    return HTTPResult(
      statusCode: scripted.statusCode,
      headers: scripted.headers,
      body: scripted.body.prefix(cap)
    )
  }
}

// MARK: - Recorded fields

public extension RecordingHTTPExecutor {
  struct UnscriptedRequest: Error {
    public let url: String
  }

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
