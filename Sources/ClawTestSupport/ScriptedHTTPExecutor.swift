import ClawCore
import Foundation

/// A transport failure whose description can embed a secret, to test redaction.
public struct ScriptedTransportFailure: Error, CustomStringConvertible, Sendable {
  public let message: String

  public init(message: String) {
    self.message = message
  }

  public var description: String { message }
}

/// Parks a scripted stream's body producer inside the exchange: `started` opens on entry (so a test
/// knows the consumer is live inside the transfer), and the producer then waits on `release` before
/// it may send. Ignoring cancellation is deliberate — a held producer must outlive a cancel, which is
/// what a shutdown-grace test is there to observe. Always pair it with a `defer { release.open() }`
/// so teardown cannot strand the producer.
public struct ScriptedStreamHold: Sendable {
  public let started: AsyncGate
  public let release: AsyncGate

  public init(started: AsyncGate = AsyncGate(), release: AsyncGate = AsyncGate()) {
    self.started = started
    self.release = release
  }
}

/// The canonical scripted `HTTPExecuting & HTTPStreaming` double: it plays back a queue of HTTP
/// outcomes in dispatch order and records every request it received, so retry counts, request
/// shaping, and header handling can be asserted. Reach for it whenever the order of calls is what a
/// test is about — `RecordingHTTPExecutor` is the other half of the split, a buffered-only stub that
/// answers from a URL-keyed map and cares nothing for order.
///
/// It holds the seam's contract rather than shortcutting it: the body policy must match the entry
/// point, the handoff runs once before the scripted answer, and a scripted stream is an owning
/// exchange with the same bound the real executor would give it.
public actor ScriptedHTTPExecutor: HTTPExecuting, HTTPStreaming {
  public enum Step: Sendable {
    case ok(HTTPResult)
    case fail(ScriptedTransportFailure)
    case stream(HTTPStreamHead, [Data])
    case streamFailure(HTTPStreamHead, [Data], ScriptedTransportFailure)
    /// Builds a streaming response from the recorded request, for protocols whose reply must echo
    /// a generated request identifier.
    case respondingStream(
      @Sendable (HTTPRequest) throws -> (head: HTTPStreamHead, chunks: [Data])
    )
    /// A typed transport failure with the disposition under test. Tests state the disposition; they
    /// never leave it to be guessed from the message.
    case transportFailure(HTTPTransportFailure)
    /// Chunks the producer may not send until the hold is released, so a test can keep a stream open
    /// and watch what its consumer does meanwhile.
    case blockedStream(HTTPStreamHead, [Data], ScriptedStreamHold)
  }

  public struct Recorded: Sendable {
    public let method: HTTPMethod
    public let url: String
    public let headers: [String: String]
    public let body: Data
    public let timeout: Duration
    public let responseBodyPolicy: HTTPResponseBodyPolicy
    public let carriedHandoff: Bool
  }

  private var steps: [Step]
  public private(set) var recorded: [Recorded] = []

  public init(_ steps: [Step]) {
    self.steps = steps
  }

  public func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    guard case .buffered = request.responseBodyPolicy else {
      throw HTTPTransportFailure.policyMismatch(
        HTTPResponseBodyPolicy.bufferedPolicyRequiredMessage
      )
    }
    try begin(request)

    guard !steps.isEmpty else {
      throw ScriptedTransportFailure(message: "scripted executor exhausted")
    }
    switch steps.removeFirst() {
    case .ok(let result): return result
    case .fail(let error): throw error
    case .transportFailure(let failure): throw failure
    case .stream, .streamFailure, .respondingStream, .blockedStream:
      throw ScriptedTransportFailure(message: "expected buffered step, got streaming step")
    }
  }

  public func openStream(_ request: HTTPRequest) async throws -> HTTPStreamExchange {
    guard case .streaming(let maximumUnreadBytes, let errorBytes) = request.responseBodyPolicy
    else {
      throw HTTPTransportFailure.policyMismatch(
        HTTPResponseBodyPolicy.streamingPolicyRequiredMessage
      )
    }
    try begin(request)

    guard !steps.isEmpty else {
      throw HTTPTransportFailure(
        disposition: .mayHaveBeenSent,
        safeMessage: "scripted executor exhausted"
      )
    }
    switch steps.removeFirst() {
    case .transportFailure(let failure):
      throw failure
    case .stream(let head, let chunks):
      return Self.exchange(
        head: head,
        chunks: chunks,
        unread: maximumUnreadBytes,
        error: errorBytes
      )
    case .streamFailure(let head, let chunks, let failure):
      return Self.exchange(
        head: head,
        chunks: chunks,
        unread: maximumUnreadBytes,
        error: errorBytes,
        failure: HTTPTransportFailure(
          disposition: .mayHaveBeenSent,
          safeMessage: failure.message
        )
      )
    case .respondingStream(let response):
      let reply = try response(request)
      return Self.exchange(
        head: reply.head,
        chunks: reply.chunks,
        unread: maximumUnreadBytes,
        error: errorBytes
      )
    case .blockedStream(let head, let chunks, let hold):
      return Self.exchange(
        head: head,
        chunks: chunks,
        unread: maximumUnreadBytes,
        error: errorBytes,
        hold: hold
      )
    case .ok, .fail:
      throw HTTPTransportFailure(
        disposition: .mayHaveBeenSent,
        safeMessage: "expected streaming step, got buffered step"
      )
    }
  }
}

// MARK: - Recorded fields

public extension ScriptedHTTPExecutor {
  /// URLs of every recorded call, in dispatch order.
  var requestedURLs: [String] {
    recorded.map(\.url)
  }

  var lastURL: String? {
    recorded.last?.url
  }

  var lastHeaders: [String: String] {
    recorded.last?.headers ?? [:]
  }

  var lastBody: Data? {
    recorded.last?.body
  }
}

// MARK: - Scripting

private extension ScriptedHTTPExecutor {
  /// Runs the call's handoff and then, only if it let the attempt through, records the call — the
  /// order the real executor takes. `recorded` is read as what was dispatched, so a refused attempt
  /// must leave no trace of a dispatch that never happened.
  func begin(_ request: HTTPRequest) throws {
    try request.beginHandoff?()
    recorded.append(
      Recorded(
        method: request.method,
        url: request.url,
        headers: request.headers,
        body: request.body ?? Data(),
        timeout: request.timeout,
        responseBodyPolicy: request.responseBodyPolicy,
        carriedHandoff: request.beginHandoff != nil
      )
    )
  }

  static func exchange(
    head: HTTPStreamHead,
    chunks: [Data],
    unread: Int,
    error: Int,
    failure: HTTPTransportFailure? = nil,
    hold: ScriptedStreamHold? = nil
  ) -> HTTPStreamExchange {
    HTTPStreamExchange.make(
      head: head,
      maximumUnreadBodyBytes: HTTPResponseBodyPolicy.isSuccess(head.statusCode) ? unread : error
    ) { sink in
      if let hold {
        hold.started.open()
        await hold.release.waitIgnoringCancellation()
      }
      do {
        for chunk in chunks {
          try await sink.send(chunk)
        }
      } catch {
        return .cancelled(.mayHaveBeenSent)
      }
      if let failure {
        return .failed(failure)
      }
      return .completed
    }
  }
}
