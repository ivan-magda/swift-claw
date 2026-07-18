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
      throw HTTPTransportFailure.policyMismatch(
        HTTPResponseBodyPolicy.bufferedPolicyRequiredMessage
      )
    }

    let response = try await submit(request)
    let statusCode = Int(response.status.code)
    let isSuccess = HTTPResponseBodyPolicy.isSuccess(statusCode)

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
      throw oversized
    } catch {
      throw Self.classifyPostHead(error)
    }
  }

  public func openStream(_ request: HTTPRequest) async throws -> HTTPStreamExchange {
    guard
      case .streaming(let maximumUnreadBytes, let errorBytes) = request.responseBodyPolicy
    else {
      throw HTTPTransportFailure.policyMismatch(
        HTTPResponseBodyPolicy.streamingPolicyRequiredMessage
      )
    }

    let response = try await submit(request)
    let statusCode = Int(response.status.code)
    let isSuccess = HTTPResponseBodyPolicy.isSuccess(statusCode)
    let body = response.body

    return HTTPStreamExchange.make(
      head: HTTPStreamHead(
        statusCode: statusCode,
        headers: Self.responseHeaders(response)
      ),
      maximumUnreadBodyBytes: isSuccess ? maximumUnreadBytes : errorBytes
    ) { sink in
      await Self.forward(body, into: sink, totalBytes: isSuccess ? nil : errorBytes)
    }
  }
}

// MARK: - Submission

private extension AsyncHTTPExecutor {
  func submit(_ request: HTTPRequest) async throws -> HTTPClientResponse {
    let clientRequest = makeClientRequest(request)
    try request.beginHandoff?()

    do {
      return try await client.execute(
        clientRequest,
        timeout: TimeAmount(request.timeout)
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
}

// MARK: - Body handling

private extension AsyncHTTPExecutor {
  enum OversizedBodyHandling {
    case fails
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
          throw HTTPTransportFailure.oversizedBody(cap: cap)
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

          guard remaining > 0 else {
            break
          }

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
      return .failed(
        HTTPTransportFailure(
          disposition: .mayHaveBeenSent,
          safeMessage:
            "response body chunk of \(weight) bytes exceeds the \(capacity)-byte unread limit"
        )
      )
    case .channelFinished:
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

extension AsyncHTTPExecutor {
  static func classify(_ error: any Error) -> HTTPTransportFailure {
    HTTPTransportFailure(
      disposition: provesNothingWasSent(error) ? .definitelyNotSent : .mayHaveBeenSent,
      safeMessage: "\(error)"
    )
  }

  static func classifyPostHead(_ error: any Error) -> HTTPTransportFailure {
    HTTPTransportFailure(disposition: .mayHaveBeenSent, safeMessage: "\(error)")
  }

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
