import AsyncHTTPClient
import ClawCore
import Foundation
import NIOCore
import NIOFoundationCompat

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
    let cap = Self.isSuccess(statusCode) ? successBytes : errorBytes

    do {
      return HTTPResult(
        statusCode: statusCode,
        headers: Self.responseHeaders(response),
        body: try await Self.collect(response.body, upTo: cap)
      )
    } catch {
      throw Self.classify(error)
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
  /// Reads at most `cap` bytes and stops. An over-cap body is delivered truncated to exactly the
  /// cap: the cap bounds allocation, and the first bytes of an oversized error are the ones worth
  /// reading. Abandoning the sequence early also stops pulling the rest off the connection.
  static func collect(_ body: HTTPClientResponse.Body, upTo cap: Int) async throws -> Data {
    var collected = Data()
    for try await buffer in body {
      let remaining = cap - collected.count
      guard remaining > 0 else { break }
      let view = buffer.readableBytesView
      guard view.count <= remaining else {
        collected.append(contentsOf: view.prefix(remaining))
        break
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
      return .failed(classify(error))
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

// MARK: - Transport Failure Classification

private extension AsyncHTTPExecutor {
  /// A policy of the wrong shape for its entry point is a programming mistake, and it is caught
  /// before the handoff — so nothing was submitted and saying so proves itself.
  static func policyMismatch(_ message: String) -> HTTPTransportFailure {
    HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: message)
  }

  static func classify(_ error: any Error) -> HTTPTransportFailure {
    HTTPTransportFailure(
      disposition: provesNothingWasSent(error) ? .definitelyNotSent : .mayHaveBeenSent,
      safeMessage: "\(error)"
    )
  }

  /// The entire allowlist for claiming a request never left, and it rests on one transport fact: the
  /// peer refused the connection, so no channel to write a request on ever existed.
  ///
  /// Everything else stays conservative — a connect timeout, a deadline, an unknown pre-head failure
  /// can all race request bytes onto the wire, and an error the transport does not type as a refusal
  /// proves nothing. Only these typed facts decide; an error's text never does.
  static func provesNothingWasSent(_ error: any Error) -> Bool {
    if let ioError = error as? IOError {
      return ioError.errnoCode == ECONNREFUSED
    }
    #if canImport(Network)
      if let posixError = error as? HTTPClient.NWPOSIXError {
        return posixError.errorCode == .ECONNREFUSED
      }
    #endif
    return false
  }
}
