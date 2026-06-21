import AsyncHTTPClient
import ClawCore
import Foundation
import NIOCore

/// AHC-backed executor injected at the `clawd` root into both Telegram and LLM clients. Opts into
/// gzip (decompression is enabled on the shared `HTTPClient` configuration — see `clawd`) and caps
/// the collected body. Response headers are collected case-as-received; `HTTPResult.header` matches
/// case-insensitively.
public struct AsyncHTTPExecutor: HTTPExecuting {
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
    var request = HTTPClientRequest(url: url)
    request.method = .POST
    request.headers.add(name: "content-type", value: "application/json")
    request.headers.add(name: "accept-encoding", value: "gzip")
    for (name, value) in headers {
      request.headers.add(name: name, value: value)
    }
    request.body = .bytes(ByteBuffer(bytes: jsonBody))

    let response = try await client.execute(request, timeout: .seconds(Int64(timeoutSeconds)))
    let buffer = try await response.body.collect(upTo: maxResponseBytes)

    var responseHeaders: [String: String] = [:]
    // Duplicate header names collapse to the last value — fine for the scalar cost/rate-limit headers we read.
    for header in response.headers {
      responseHeaders[header.name] = header.value
    }

    return HTTPResult(
      statusCode: Int(response.status.code),
      headers: responseHeaders,
      body: Data(buffer: buffer)
    )
  }
}
