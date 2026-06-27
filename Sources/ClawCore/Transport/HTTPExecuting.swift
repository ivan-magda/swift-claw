import Foundation

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
    let target = name.lowercased()
    return headers.first { $0.key.lowercased() == target }?.value
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
    let target = name.lowercased()
    return headers.first { $0.key.lowercased() == target }?.value
  }
}

public protocol HTTPExecuting: Sendable {
  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult
}

public protocol HTTPStreaming: Sendable {
  func postStream(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> (head: HTTPStreamHead, body: AsyncThrowingStream<Data, Error>)
}
