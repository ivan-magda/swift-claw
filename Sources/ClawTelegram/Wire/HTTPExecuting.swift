import AsyncHTTPClient
import ClawCore
import Foundation
import NIOCore

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// AHC-backed executor injected at the `clawd` root into both Telegram and LLM clients. Opts into
/// gzip (decompression is enabled on the shared `HTTPClient` configuration — see `clawd`) and caps
/// the collected body. Response headers are collected case-as-received; `HTTPResult.header` matches
/// case-insensitively.
public struct AsyncHTTPExecutor: HTTPExecuting, HTTPStreaming {
  private let client: HTTPClient
  private let maxResponseBytes: Int

  public init(client: HTTPClient, maxResponseBytes: Int = 16 * 1024 * 1024) {
    self.client = client
    self.maxResponseBytes = maxResponseBytes
  }

  public func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult {
    let request = makeRequest(url: url, headers: headers, jsonBody: jsonBody)
    let response = try await client.execute(request, timeout: .seconds(Int64(timeoutSeconds)))
    let buffer = try await response.body.collect(upTo: maxResponseBytes)

    return HTTPResult(
      statusCode: Int(response.status.code),
      headers: responseHeaders(response),
      body: Data(buffer: buffer)
    )
  }

  public func get(
    url: String,
    headers: [String: String],
    timeoutSeconds: Int,
    maxBodyBytes: Int
  ) async throws -> HTTPResult {
    var request = HTTPClientRequest(url: url)
    request.method = .GET
    request.headers.add(name: "accept-encoding", value: "gzip")
    for (name, value) in headers {
      request.headers.add(name: name, value: value)
    }

    let response = try await client.execute(request, timeout: .seconds(Int64(timeoutSeconds)))
    let buffer = try await response.body.collect(upTo: maxBodyBytes)

    return HTTPResult(
      statusCode: Int(response.status.code),
      headers: responseHeaders(response),
      body: Data(buffer: buffer)
    )
  }

  public func postStream(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> (head: HTTPStreamHead, body: AsyncThrowingStream<Data, Error>) {
    let request = makeRequest(url: url, headers: headers, jsonBody: jsonBody)

    let response: HTTPClientResponse
    do {
      response = try await client.execute(request, timeout: .seconds(Int64(timeoutSeconds)))
    } catch {
      throw classifyPreHeadError(error)
    }

    // Unbounded buffering: a briefly stalled consumer must never kill the stream. Memory is
    // bounded by consumer liveness, not by parser limits — the sole consumer
    // (`OpenAICompatibleProvider.stream`) never blocks between chunks, and the turn's wall-clock
    // deadline cancels the whole chain, so the worst case is link-rate × deadline from a hostile
    // provider (an accepted owner-configured risk). A consumer that can stall indefinitely must
    // not use this seam without restoring backpressure.
    let body = AsyncThrowingStream<Data, Error> { continuation in
      let task = Task {
        do {
          for try await buffer in response.body {
            continuation.yield(Data(buffer: buffer))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }

    return (
      HTTPStreamHead(statusCode: Int(response.status.code), headers: responseHeaders(response)),
      body
    )
  }
}

// MARK: - Request Construction

private extension AsyncHTTPExecutor {
  func makeRequest(
    url: String,
    headers: [String: String],
    jsonBody: Data
  ) -> HTTPClientRequest {
    var request = HTTPClientRequest(url: url)
    request.method = .POST
    request.headers.add(name: "content-type", value: "application/json")
    request.headers.add(name: "accept-encoding", value: "gzip")
    for (name, value) in headers {
      request.headers.add(name: name, value: value)
    }
    request.body = .bytes(ByteBuffer(bytes: jsonBody))
    return request
  }

  func responseHeaders(_ response: HTTPClientResponse) -> [String: String] {
    var result: [String: String] = [:]
    for header in response.headers {
      result[header.name] = header.value
    }
    return result
  }
}

// MARK: - Transport Error Classification

private extension AsyncHTTPExecutor {
  func classifyPreHeadError(_ error: Error) -> ProviderError {
    let message = "\(error)"
    if isClearlyPreSendConnectFailure(error) {
      return .connectFailed(message: message)
    }
    return .retryable(status: nil, message: "transport failed before response head: \(message)")
  }

  func isClearlyPreSendConnectFailure(_ error: Error) -> Bool {
    if let httpError = error as? HTTPClientError {
      return httpError == .connectTimeout
    }
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
