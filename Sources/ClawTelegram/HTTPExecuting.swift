import AsyncHTTPClient
import Foundation
import NIOCore

public struct HTTPResult: Sendable {
  public let statusCode: Int
  public let body: Data

  public init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }
}

/// The raw HTTP send, abstracted so the client's parsing/error-mapping is testable without the network.
public protocol HTTPExecuting: Sendable {
  func post(url: String, jsonBody: Data, timeoutSeconds: Int) async throws -> HTTPResult
}

public struct AsyncHTTPExecutor: HTTPExecuting {
  private let client: HTTPClient
  private let maxResponseBytes: Int

  public init(client: HTTPClient, maxResponseBytes: Int = 16 * 1024 * 1024) {
    self.client = client
    self.maxResponseBytes = maxResponseBytes
  }

  public func post(url: String, jsonBody: Data, timeoutSeconds: Int) async throws -> HTTPResult {
    var request = HTTPClientRequest(url: url)
    request.method = .POST
    request.headers.add(name: "content-type", value: "application/json")
    request.body = .bytes(ByteBuffer(bytes: jsonBody))

    let response = try await client.execute(request, timeout: .seconds(Int64(timeoutSeconds)))
    let buffer = try await response.body.collect(upTo: maxResponseBytes)

    return HTTPResult(
      statusCode: Int(response.status.code),
      body: Data(buffer: buffer)
    )
  }
}
