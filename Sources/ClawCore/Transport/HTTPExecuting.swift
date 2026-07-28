import Foundation

// MARK: - Responses

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
  func caseInsensitiveValue(for key: String) -> String? {
    let target = key.lowercased()
    return first { $0.key.lowercased() == target }?.value
  }

  func addingDefault(_ name: String, _ value: String) -> [String: String] {
    guard caseInsensitiveValue(for: name) == nil else {
      return self
    }

    var merged = self
    merged[name] = value

    return merged
  }
}

// MARK: - Requests

public enum HTTPMethod: String, Sendable, Equatable {
  case get = "GET"
  case post = "POST"
}

/// Whether an attempt could have reached the server.
public enum HTTPTransmissionDisposition: Sendable, Equatable {
  /// No byte of the request could have been written.
  case definitelyNotSent
  /// The request may have been written and acted upon.
  case mayHaveBeenSent
}

public struct HTTPTransportFailure: Error, Sendable, Equatable {
  public let disposition: HTTPTransmissionDisposition
  public let safeMessage: String

  public init(disposition: HTTPTransmissionDisposition, safeMessage: String) {
    self.disposition = disposition
    self.safeMessage = safeMessage
  }
}

public extension HTTPTransportFailure {
  static func policyMismatch(_ message: String) -> HTTPTransportFailure {
    HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: message)
  }

  static func oversizedBody(cap: Int) -> HTTPTransportFailure {
    HTTPTransportFailure(
      disposition: .mayHaveBeenSent,
      safeMessage: "response body exceeds the \(cap)-byte limit"
    )
  }

  /// Whether this is the transport's refusal of a body past `cap`. The type carries no case tag, so
  /// recognizing that refusal means comparing against the value the factory builds — done here, once,
  /// rather than by each caller re-deriving the message the factory happens to format.
  func isOversizedBody(cap: Int) -> Bool {
    self == .oversizedBody(cap: cap)
  }
}

/// How much of a response body an executor may hold, and whether the caller reads it as one value or
/// as a stream. The success and error caps are separate because they answer different questions: a
/// success body is the payload, an error body is a diagnostic worth only a few kilobytes.
public enum HTTPResponseBodyPolicy: Sendable, Equatable {
  /// Collect the whole body, capped at `successBytes` for a 2xx and `errorBytes` otherwise. The two
  /// caps bound the same allocation but part company at their limit, because only one of the two
  /// bodies survives losing its tail: an over-cap success body fails the request, since a payload
  /// handed back short is indistinguishable from a complete one, while an over-cap error body is
  /// delivered truncated to exactly the cap, since the first bytes of a diagnostic are the useful
  /// ones.
  case buffered(successBytes: Int, errorBytes: Int)
  /// Hand the caller a live body. `maximumUnreadBytes` bounds what may sit unread between the
  /// transport and the parser on a 2xx — the producer suspends there rather than dropping a chunk —
  /// while a non-success body is collected whole and truncated to `errorBytes`.
  case streaming(maximumUnreadBytes: Int, errorBytes: Int)
}

public extension HTTPResponseBodyPolicy {
  /// The unread-byte allowance for a successful inference stream. A server that outruns the parser
  /// suspends here instead of growing the queue without limit.
  static let maximumUnreadStreamBytes = 4 * 1024 * 1024
  /// How much of a non-success body is worth keeping as a diagnostic.
  static let diagnosticBodyBytes = 64 * 1024
  /// What a convenience request collects when its caller states no cap of its own.
  static let defaultBufferedBodyBytes = 16 * 1024 * 1024

  /// The refusal message the buffered entry point raises for a policy of the wrong shape. Shared so
  /// production and its doubles state the one contract, not three copies.
  static let bufferedPolicyRequiredMessage = "execute needs a buffered response body policy"
  /// The refusal message the streaming entry point raises for a policy of the wrong shape.
  static let streamingPolicyRequiredMessage = "openStream needs a streaming response body policy"

  /// Whether a status code selects the success side of the two-cap contract: the success cap over the
  /// error cap, and the payload disposition over the diagnostic one. The single definition every
  /// executor consults so a change to the success band cannot leave a double asserting a stale one.
  static func isSuccess(_ statusCode: Int) -> Bool {
    (200..<300).contains(statusCode)
  }
}

/// One outbound request. Every executor path is built from this value, so an authentication form
/// body and an inference POST take the same road through the transport.
public struct HTTPRequest: Sendable {
  public let method: HTTPMethod
  public let url: String
  public let headers: [String: String]
  public let body: Data?
  public let timeout: Duration
  public let responseBodyPolicy: HTTPResponseBodyPolicy

  /// The attempt's linearization point, invoked exactly once immediately before the request is
  /// handed to the transport.
  public let beginHandoff: (@Sendable () throws -> Void)?

  public init(
    method: HTTPMethod,
    url: String,
    headers: [String: String],
    body: Data?,
    timeout: Duration,
    responseBodyPolicy: HTTPResponseBodyPolicy,
    beginHandoff: (@Sendable () throws -> Void)? = nil
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeout = timeout
    self.responseBodyPolicy = responseBodyPolicy
    self.beginHandoff = beginHandoff
  }
}

// MARK: - Executor seams

public protocol HTTPExecuting: Sendable {
  /// Sends `request` and collects its whole body. Requires a `.buffered` policy.
  ///
  /// - Throws: `HTTPTransportFailure` when the transport fails or a success body outgrows its cap,
  ///   or `beginHandoff`'s own error when the caller refuses the submission.
  func execute(_ request: HTTPRequest) async throws -> HTTPResult
}

public extension HTTPExecuting {
  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int,
    maxBodyBytes: Int = HTTPResponseBodyPolicy.defaultBufferedBodyBytes
  ) async throws -> HTTPResult {
    try await execute(
      HTTPRequest(
        method: .post,
        url: url,
        headers: headers.addingDefault("Content-Type", "application/json"),
        body: jsonBody,
        timeout: .seconds(timeoutSeconds),
        responseBodyPolicy: .buffered(successBytes: maxBodyBytes, errorBytes: maxBodyBytes)
      )
    )
  }

  func get(
    url: String,
    headers: [String: String],
    timeoutSeconds: Int,
    maxBodyBytes: Int
  ) async throws -> HTTPResult {
    try await execute(
      HTTPRequest(
        method: .get,
        url: url,
        headers: headers,
        body: nil,
        timeout: .seconds(timeoutSeconds),
        responseBodyPolicy: .buffered(successBytes: maxBodyBytes, errorBytes: maxBodyBytes)
      )
    )
  }
}

public protocol HTTPStreaming: Sendable {
  /// Sends `request` and returns once its response head has arrived, handing back an exchange that
  /// owns the rest of the transfer. Requires a `.streaming` policy.
  ///
  /// - Throws: `HTTPTransportFailure` when the transport fails before the head, or `beginHandoff`'s
  ///   own error when the caller refuses the submission.
  func openStream(_ request: HTTPRequest) async throws -> HTTPStreamExchange
}

// MARK: - Stream exchange

/// How a stream's body transfer ended.
public enum HTTPStreamTermination: Sendable, Equatable {
  case completed
  case failed(HTTPTransportFailure)
  case cancelled(HTTPTransmissionDisposition)
}

/// An owning, bounded streaming response: the head, a single-consumer body, and the producer that
/// fills it. The exchange owns that producer's lifetime, so joining the exchange joins the transfer.
public struct HTTPStreamExchange: Sendable {
  public let head: HTTPStreamHead
  public let body: HTTPBodySequence

  private let owner: HTTPStreamOwner

  /// Builds an exchange around `operation`, which fills the sink and reports how the transfer ended.
  ///
  /// - Parameter maximumUnreadBodyBytes: what may sit unread between `operation` and the consumer.
  ///   `operation` suspends on a full buffer; it is never asked to drop a chunk.
  public static func make(
    head: HTTPStreamHead,
    maximumUnreadBodyBytes: Int,
    operation: @escaping @Sendable (HTTPBodySink) async -> HTTPStreamTermination
  ) -> HTTPStreamExchange {
    let channel = BoundedAsyncChannel<Data>(capacity: maximumUnreadBodyBytes) { chunk in
      chunk.count
    }

    let owner = HTTPStreamOwner(
      channel: channel,
      resolve: { reported, _ in
        reported
      },
      channelError: { terminal in
        guard case .failed(let failure) = terminal else {
          return nil
        }
        return failure
      }
    )

    let producer = Task {
      let termination = await operation(HTTPBodySink(channel: channel))
      owner.finish(reporting: termination)
    }
    owner.attach(producer: producer)

    return HTTPStreamExchange(
      head: head,
      body: HTTPBodySequence(channel: channel, owner: owner),
      owner: owner
    )
  }

  public func cancel() {
    owner.cancel()
  }

  public func cancelAndAwait() async -> HTTPStreamTermination {
    owner.cancel()
    return await owner.awaitTermination()
  }

  public func awaitTermination() async -> HTTPStreamTermination {
    await owner.awaitTermination()
  }
}

/// The write end of a stream exchange's body.
public struct HTTPBodySink: Sendable {
  fileprivate let channel: BoundedAsyncChannel<Data>

  /// Suspends until the consumer has room for `bytes`.
  ///
  /// - Throws: `CancellationError` or `BoundedAsyncChannelError.channelFinished` once the exchange
  ///   is cancelled, or `BoundedAsyncChannelError.elementExceedsCapacity` for a chunk larger than
  ///   the whole unread allowance, which no amount of draining could ever admit.
  public func send(_ bytes: Data) async throws {
    try await channel.send(bytes)
  }
}

/// The read end of a stream exchange's body. Single-consumer: a second iterator throws rather than
/// silently splitting the stream.
public struct HTTPBodySequence: AsyncSequence, Sendable {
  public typealias Element = Data

  fileprivate let channel: BoundedAsyncChannel<Data>
  fileprivate let owner: HTTPStreamOwner

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      base: channel.makeAsyncIterator(),
      lease: StreamAbandonmentLease { owner.cancel() }
    )
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    fileprivate var base: BoundedAsyncChannel<Data>.Iterator
    /// Held, never read: dropping the iterator is what the lease is here to notice.
    fileprivate let lease: StreamAbandonmentLease

    public mutating func next() async throws -> Data? {
      try await base.next()
    }
  }
}

// MARK: - Stream ownership

private typealias HTTPStreamOwner = StreamTerminationOwner<Data, HTTPStreamTermination>
