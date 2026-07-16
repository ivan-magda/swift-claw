import AsyncHTTPClient
import ClawCore
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// AHC-backed executor injected at the `clawd` root into both Telegram and LLM clients. Opts into
/// gzip (decompression is enabled on the shared `HTTPClient` configuration — see `clawd`) and holds
/// only what the request's body policy allows. Response headers are collected case-as-received;
/// `HTTPResult.getHeader` matches case-insensitively.
public struct AsyncHTTPExecutor: HTTPExecuting, HTTPStreaming {
  private let client: HTTPClient

  public init(client: HTTPClient) {
    self.client = client
  }

  public func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    guard case .buffered(let successBytes, let errorBytes) = request.responseBodyPolicy else {
      throw Self.policyMismatch("execute needs a buffered response body policy")
    }

    let response = try await submit(request)
    let statusCode = Int(response.status.code)
    let isSuccess = Self.isSuccess(statusCode)

    do {
      return HTTPResult(
        statusCode: statusCode,
        headers: Self.responseHeaders(response),
        body: try await Self.collect(
          response.body,
          upTo: isSuccess ? successBytes : errorBytes,
          whenOversized: isSuccess ? .fails : .truncates
        )
      )
    } catch let oversized as HTTPTransportFailure {
      // `collect` is the only source of this type here — the transport raises its own error types —
      // so passing it through cannot swallow a failure that still needs classifying.
      throw oversized
    } catch {
      throw Self.classifyPostHead(error)
    }
  }

  public func openStream(_ request: HTTPRequest) async throws -> HTTPStreamExchange {
    guard case .streaming(let maximumUnreadBytes, let errorBytes) = request.responseBodyPolicy
    else {
      throw Self.policyMismatch("openStream needs a streaming response body policy")
    }

    let response = try await submit(request)
    let statusCode = Int(response.status.code)
    let isSuccess = Self.isSuccess(statusCode)
    let body = response.body

    // A non-success body is a diagnostic, so the whole of it is capped and it can never outgrow the
    // buffer; a successful body is the payload, and the producer suspends rather than lose a byte.
    return HTTPStreamExchange.make(
      head: HTTPStreamHead(statusCode: statusCode, headers: Self.responseHeaders(response)),
      maximumUnreadBodyBytes: isSuccess ? maximumUnreadBytes : errorBytes
    ) { sink in
      await Self.forward(body, into: sink, totalBytes: isSuccess ? nil : errorBytes)
    }
  }
}

// MARK: - Submission

private extension AsyncHTTPExecutor {
  /// The only road to the wire. Both entry points funnel through here so the handoff cannot drift
  /// out of step between them: it is invoked once, unconditionally, with nothing but the submission
  /// after it.
  func submit(_ request: HTTPRequest) async throws -> HTTPClientResponse {
    let clientRequest = makeClientRequest(request)
    // The linearization point. A refusal is the caller's own error and is rethrown untouched: it
    // authored that error, and nothing has been sent.
    try request.beginHandoff?()

    do {
      return try await client.execute(
        clientRequest,
        timeout: .seconds(Int64(request.timeoutSeconds))
      )
    } catch {
      throw Self.classify(error)
    }
  }

  func makeClientRequest(_ request: HTTPRequest) -> HTTPClientRequest {
    var clientRequest = HTTPClientRequest(url: request.url)
    switch request.method {
    case .get:
      clientRequest.method = .GET
    case .post:
      clientRequest.method = .POST
    }
    for (name, value) in request.headers {
      clientRequest.headers.add(name: name, value: value)
    }
    if !clientRequest.headers.contains(name: "accept-encoding") {
      clientRequest.headers.add(name: "accept-encoding", value: "gzip")
    }
    if let body = request.body {
      clientRequest.body = .bytes(ByteBuffer(bytes: body))
    }
    return clientRequest
  }

  static func responseHeaders(_ response: HTTPClientResponse) -> [String: String] {
    var result: [String: String] = [:]
    for header in response.headers {
      result[header.name] = header.value
    }
    return result
  }

  static func isSuccess(_ statusCode: Int) -> Bool {
    (200..<300).contains(statusCode)
  }
}

// MARK: - Body handling

private extension AsyncHTTPExecutor {
  /// What becomes of a body that outgrows its cap. Allocation stops at the cap either way; the
  /// question this answers is whether what was read is still worth handing back.
  enum OversizedBodyHandling {
    /// A payload short of its tail cannot be told apart from a whole one, so the response is
    /// reported malformed instead of being passed off as complete.
    case fails
    /// A diagnostic is still a diagnostic with its tail missing, and its first bytes are the ones
    /// worth reading.
    case truncates
  }

  /// Reads at most `cap` bytes and stops there, leaving `handling` to say what an over-cap body
  /// means. Leaving the sequence early — by return or by throw — also stops pulling the rest off the
  /// connection.
  static func collect(
    _ body: HTTPClientResponse.Body,
    upTo cap: Int,
    whenOversized handling: OversizedBodyHandling
  ) async throws -> Data {
    var collected = Data()
    for try await buffer in body {
      let view = buffer.readableBytesView
      let remaining = cap - collected.count
      guard view.count <= remaining else {
        switch handling {
        case .fails:
          throw oversizedBody(cap: cap)
        case .truncates:
          collected.append(contentsOf: view.prefix(remaining))
          return collected
        }
      }
      collected.append(contentsOf: view)
    }
    return collected
  }

  /// Pumps the response body into the exchange, suspending whenever the consumer is behind.
  ///
  /// - Parameter totalBytes: a ceiling on the whole transfer, for a diagnostic body that is read to
  ///   the end rather than streamed. `nil` streams everything, dropping nothing.
  static func forward(
    _ body: HTTPClientResponse.Body,
    into sink: HTTPBodySink,
    totalBytes: Int?
  ) async -> HTTPStreamTermination {
    var forwarded = 0
    do {
      for try await buffer in body {
        let view = buffer.readableBytesView
        let chunk: Data
        if let totalBytes {
          let remaining = totalBytes - forwarded
          guard remaining > 0 else { break }
          chunk = view.count > remaining ? Data(view.prefix(remaining)) : Data(view)
        } else {
          chunk = Data(view)
        }
        forwarded += chunk.count
        try await sink.send(chunk)
      }
      return .completed
    } catch is CancellationError {
      return .cancelled(.mayHaveBeenSent)
    } catch let error as BoundedAsyncChannelError {
      return terminationForSink(error)
    } catch {
      return .failed(classifyPostHead(error))
    }
  }

  static func terminationForSink(_ error: BoundedAsyncChannelError) -> HTTPStreamTermination {
    switch error {
    case .elementExceedsCapacity(let weight, let capacity):
      // The one bound suspending cannot absorb: no amount of draining would ever admit this chunk,
      // so the transfer fails instead of parking forever.
      return .failed(
        HTTPTransportFailure(
          disposition: .mayHaveBeenSent,
          safeMessage: "response body chunk of \(weight) bytes exceeds the \(capacity)-byte "
            + "unread limit"
        )
      )
    case .channelFinished:
      // Nothing but `cancel()` closes the body ahead of its producer.
      return .cancelled(.mayHaveBeenSent)
    case .negativeWeight, .multipleIterators:
      return .failed(
        HTTPTransportFailure(
          disposition: .mayHaveBeenSent,
          safeMessage: "response body could not be delivered: \(error)"
        )
      )
    }
  }
}

// MARK: - Transport Failures

private extension AsyncHTTPExecutor {
  /// A policy of the wrong shape for its entry point is a programming mistake, and it is caught
  /// before the handoff — so nothing was submitted and saying so proves itself.
  static func policyMismatch(_ message: String) -> HTTPTransportFailure {
    HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: message)
  }

  /// A success body past its cap. The disposition is not in doubt: a response head came back, so the
  /// request plainly reached the server. The message names the cap, never the body.
  static func oversizedBody(cap: Int) -> HTTPTransportFailure {
    HTTPTransportFailure(
      disposition: .mayHaveBeenSent,
      safeMessage: "response body exceeds the \(cap)-byte limit"
    )
  }
}

// MARK: - Transport Failure Classification

extension AsyncHTTPExecutor {
  /// Classifies a failure raised before any response head arrived, where the allowlist below is the
  /// one thing that may find a request clean.
  static func classify(_ error: any Error) -> HTTPTransportFailure {
    HTTPTransportFailure(
      disposition: provesNothingWasSent(error) ? .definitelyNotSent : .mayHaveBeenSent,
      safeMessage: "\(error)"
    )
  }

  /// Classifies a failure raised once a response head has arrived, which nothing may call clean.
  ///
  /// A head is proof that a request channel existed and was written to, so the allowlist's premise —
  /// that no channel ever became writable — is provably false here, whatever error the transport
  /// went on to raise. Consulting it after a head could hand a caller a `definitelyNotSent` for a
  /// request the server has already acted on and billed.
  static func classifyPostHead(_ error: any Error) -> HTTPTransportFailure {
    HTTPTransportFailure(disposition: .mayHaveBeenSent, safeMessage: "\(error)")
  }

  /// The entire allowlist for claiming a request never left, and it rests on one transport fact: the
  /// peer refused the connection, so no channel to write a request on ever existed.
  ///
  /// The transport spells that refusal differently by platform: a bare `IOError`/`NWPOSIXError` on
  /// the direct-connect paths, and — from NIOPosix's happy-eyeballs connector on Linux — a
  /// `NIOConnectionError` bundling every per-target attempt. The bundle is clean only when it holds
  /// at least one attempt and every attempt refused; a mix or an empty set means some channel may
  /// have opened, so it stays conservative.
  ///
  /// Everything else stays conservative — a connect timeout, a deadline, an unknown pre-head failure
  /// can all race request bytes onto the wire, and an error the transport does not type as a refusal
  /// proves nothing. Only these typed facts decide; an error's text never does.
  static func provesNothingWasSent(_ error: any Error) -> Bool {
    if isConnectionRefused(error) {
      return true
    }
    #if canImport(Network)
      if let posixError = error as? HTTPClient.NWPOSIXError {
        return posixError.errorCode == .ECONNREFUSED
      }
    #endif
    if let connectionError = error as? NIOConnectionError {
      return !connectionError.connectionErrors.isEmpty
        && connectionError.connectionErrors.allSatisfy { isConnectionRefused($0.error) }
    }
    return false
  }

  static func isConnectionRefused(_ error: any Error) -> Bool {
    guard let ioError = error as? IOError else {
      return false
    }
    return ioError.errnoCode == ECONNREFUSED
  }
}
