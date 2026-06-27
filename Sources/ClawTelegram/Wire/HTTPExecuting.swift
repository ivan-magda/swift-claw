import AsyncHTTPClient
import ClawCore
import Foundation
import NIOCore

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

private struct HTTPStreamBufferOverflowError: Error, CustomStringConvertible {
  let maxBufferedChunks: Int

  var description: String {
    "HTTP stream buffer overflow after \(maxBufferedChunks) queued chunks"
  }
}

/// AHC-backed executor injected at the `clawd` root into both Telegram and LLM clients. Opts into
/// gzip (decompression is enabled on the shared `HTTPClient` configuration — see `clawd`) and caps
/// the collected body. Response headers are collected case-as-received; `HTTPResult.header` matches
/// case-insensitively.
public struct AsyncHTTPExecutor: HTTPExecuting, HTTPStreaming {
  private static let maxStreamBufferedChunks = 16

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

    let body = AsyncThrowingStream<Data, Error>(
      bufferingPolicy: .bufferingOldest(Self.maxStreamBufferedChunks)
    ) { continuation in
      let task = Task {
        do {
          for try await buffer in response.body {
            switch continuation.yield(Data(buffer: buffer)) {
            case .enqueued:
              break
            case .dropped:
              continuation.finish(
                throwing: HTTPStreamBufferOverflowError(
                  maxBufferedChunks: Self.maxStreamBufferedChunks
                )
              )
              return
            case .terminated:
              return
            @unknown default:
              continuation.finish(
                throwing: HTTPStreamBufferOverflowError(
                  maxBufferedChunks: Self.maxStreamBufferedChunks
                )
              )
              return
            }
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

  private func makeRequest(
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

  private func responseHeaders(_ response: HTTPClientResponse) -> [String: String] {
    var result: [String: String] = [:]
    for header in response.headers {
      result[header.name] = header.value
    }
    return result
  }

  private func classifyPreHeadError(_ error: Error) -> ProviderError {
    let message = "\(error)"
    if isClearlyPreSendConnectFailure(error) {
      return .connectFailed(message: message)
    }
    return .retryable(status: nil, message: "transport failed before response head: \(message)")
  }

  private func isClearlyPreSendConnectFailure(_ error: Error) -> Bool {
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
