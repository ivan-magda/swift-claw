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
  /// Case-insensitive header lookup: HTTP field names are case-insensitive, but the header maps
  /// preserve the wire casing, so match on a lowercased key.
  func caseInsensitiveValue(for key: String) -> String? {
    let target = key.lowercased()
    return first { $0.key.lowercased() == target }?.value
  }

  /// Supplies `value` only when the caller named no header of its own for `name`. A caller's field
  /// must replace the default outright: adding both would put the same field on the wire twice.
  func addingDefault(_ name: String, _ value: String) -> [String: String] {
    guard caseInsensitiveValue(for: name) == nil else { return self }
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

/// Whether an attempt could have reached the server. It answers one question: may the far end have
/// acted on this request — billed it, sent a message — even though no response came back?
public enum HTTPTransmissionDisposition: Sendable, Equatable {
  /// No byte of the request could have been written. Only a transport fact may establish this, and
  /// only this disposition lets a caller replay the attempt without risking a double charge.
  case definitelyNotSent
  /// The request may have been written and acted upon. The conservative default: anything an
  /// executor cannot *prove* clean lands here, including every timeout and unknown failure.
  case mayHaveBeenSent
}

/// A transport failure carrying the one fact a caller's exposure accounting needs.
public struct HTTPTransportFailure: Error, Sendable, Equatable {
  public let disposition: HTTPTransmissionDisposition
  /// Diagnostic text for logs. It describes the transport only — never a request header or body —
  /// but an underlying error can still name the URL, so a caller whose URL embeds a secret (a bot
  /// token in a path, say) still redacts before logging.
  public let safeMessage: String

  public init(disposition: HTTPTransmissionDisposition, safeMessage: String) {
    self.disposition = disposition
    self.safeMessage = safeMessage
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
}

/// One outbound request. Every executor path is built from this value, so an authentication form
/// body and an inference POST take the same road through the transport.
public struct HTTPRequest: Sendable {
  public let method: HTTPMethod
  public let url: String
  public let headers: [String: String]
  public let body: Data?
  public let timeoutSeconds: Int
  public let responseBodyPolicy: HTTPResponseBodyPolicy

  /// The attempt's linearization point, invoked exactly once immediately before the request is
  /// handed to the transport. It is the caller's chance to decide, under its own lock, whether this
  /// attempt is allowed to reach the wire: returning normally moves the attempt's exposure from
  /// "not started" to "may have started", and throwing refuses the submission outright.
  ///
  /// A refusal is rethrown unchanged and nothing is sent — the caller authored that error and is the
  /// only code that knows what it means. Once this closure has returned, cancellation is
  /// conservative: the request may have been written even if no response head ever arrives.
  public let beginHandoff: (@Sendable () throws -> Void)?

  public init(
    method: HTTPMethod,
    url: String,
    headers: [String: String],
    body: Data?,
    timeoutSeconds: Int,
    responseBodyPolicy: HTTPResponseBodyPolicy,
    beginHandoff: (@Sendable () throws -> Void)? = nil
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeoutSeconds = timeoutSeconds
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
  /// JSON POST. Supplies `Content-Type` unless the caller named one, and caps both the success and
  /// the error body at `maxBodyBytes`.
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
        timeoutSeconds: timeoutSeconds,
        responseBodyPolicy: .buffered(successBytes: maxBodyBytes, errorBytes: maxBodyBytes)
      )
    )
  }

  /// Plain GET for tool fetches. The production client is configured with
  /// `RedirectConfiguration.disallow`, so a 3xx comes back as an ordinary `HTTPResult` and is capped
  /// as a diagnostic. A page past `maxBodyBytes` fails rather than arriving silently short, so a
  /// caller can tell an over-cap fetch from a whole one and say so.
  ///
  /// - Throws: `HTTPTransportFailure` when the transport fails or a success body outgrows the cap.
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
        timeoutSeconds: timeoutSeconds,
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

/// How a stream's body transfer ended. This — not the body sequence reaching its end — is the
/// authoritative outcome: a cancelled exchange closes its body cleanly, so a consumer that only
/// watched the sequence could not tell a truncated transfer from a complete one.
public enum HTTPStreamTermination: Sendable, Equatable {
  case completed
  case failed(HTTPTransportFailure)
  case cancelled(HTTPTransmissionDisposition)
}

/// An owning, bounded streaming response: the head, a single-consumer body, and the producer that
/// fills it. The exchange owns that producer's lifetime, so joining the exchange joins the transfer.
///
/// Every consumer exit path joins — `awaitTermination()` after a full read, `cancelAndAwait()`
/// otherwise. Both ignore the joiner's own cancellation and return one cached result once the
/// producer has actually stopped, so a caller can rely on there being no work left behind it.
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
      // A body transfer reports its own terminal fact; nothing about a pending cancellation reshapes
      // what the producer already observed, so the reported outcome stands as decided.
      resolve: { reported, _ in reported },
      channelError: { terminal in
        guard case .failed(let failure) = terminal else { return nil }
        return failure
      }
    )
    // A task always runs its body, even when cancelled before it starts, so `finish` always lands
    // and a join can never wait on a producer that silently never reported.
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

  /// Stops the transfer without waiting. Idempotent, and safe to call from a `deinit`.
  public func cancel() {
    owner.cancel()
  }

  /// Stops the transfer and joins it.
  public func cancelAndAwait() async -> HTTPStreamTermination {
    owner.cancel()
    return await owner.awaitTermination()
  }

  /// Joins the transfer, returning the one cached outcome once the producer has stopped.
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

/// A body transfer's owner: the shared termination machinery, closing the channel with the transport
/// failure a `.failed` outcome carries. A body reports the terminal fact it observed, so nothing
/// reshapes it at commit.
private typealias HTTPStreamOwner = StreamTerminationOwner<Data, HTTPStreamTermination>
