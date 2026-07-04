import AsyncHTTPClient
import ClawCore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import ClawTelegram

/// A scripted response for one request path.
struct ScriptedResponse: Sendable {
  let status: HTTPResponseStatus
  let headers: [(String, String)]
  let body: String
}

/// A minimal one-shot HTTP/1.1 server: responds to any request with the scripted response for
/// its URI (or 404). Bound to 127.0.0.1 on an ephemeral port.
final class ScriptedHTTPServer: @unchecked Sendable {
  private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  private var channel: Channel?
  private(set) var port = 0

  init(routes: [String: ScriptedResponse]) throws {
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(ScriptedHandler(routes: routes))
        }
      }
    channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    port = channel?.localAddress?.port ?? 0
  }

  func shutdown() {
    try? channel?.close().wait()
    try? group.syncShutdownGracefully()
  }
}

private final class ScriptedHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let routes: [String: ScriptedResponse]

  init(routes: [String: ScriptedResponse]) {
    self.routes = routes
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .head(let head) = unwrapInboundIn(data) else {
      return
    }
    let scripted =
      routes[head.uri]
      ?? ScriptedResponse(status: .notFound, headers: [], body: "missing")

    var responseHeaders = HTTPHeaders()
    responseHeaders.add(name: "content-length", value: "\(scripted.body.utf8.count)")
    for (name, value) in scripted.headers {
      responseHeaders.add(name: name, value: value)
    }
    context.write(
      wrapOutboundOut(
        .head(
          HTTPResponseHead(version: .http1_1, status: scripted.status, headers: responseHeaders)
        )
      ),
      promise: nil
    )
    context.write(
      wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: scripted.body)))),
      promise: nil
    )
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
  }
}

@Suite(.serialized) struct AsyncHTTPExecutorGetTests {
  /// `HTTPClient.syncShutdown()` is unavailable from async contexts on this toolchain, and defer
  /// bodies cannot `await`; this helper guarantees `shutdown()` runs on every exit path (the AHC
  /// `HTTPClient` deinit precondition-fails in debug builds if a client is dropped un-shut-down).
  private func withNoRedirectExecutor<Result>(
    _ operation: (AsyncHTTPExecutor) async throws -> Result
  ) async throws -> Result {
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    do {
      let result = try await operation(AsyncHTTPExecutor(client: client))
      try await client.shutdown()
      return result
    } catch {
      try? await client.shutdown()
      throw error
    }
  }

  @Test func getReturnsStatusHeadersAndBody() async throws {
    // given
    let server = try ScriptedHTTPServer(routes: [
      "/page": ScriptedResponse(
        status: .ok,
        headers: [("content-type", "text/html")],
        body: "<html><body>hello</body></html>"
      )
    ])
    defer { server.shutdown() }

    // when
    let result = try await withNoRedirectExecutor { executor in
      try await executor.get(
        url: "http://127.0.0.1:\(server.port)/page",
        headers: [:],
        timeoutSeconds: 5,
        maxBodyBytes: 1024 * 1024
      )
    }

    // then
    #expect(result.statusCode == 200)
    #expect(result.getHeader(for: "Content-Type") == "text/html")
    #expect(String(data: result.body, encoding: .utf8)?.contains("hello") == true)
  }

  /// §20 item 3 — BLOCKING verification. The SSRF design requires that a redirect is NOT followed
  /// automatically: the 3xx must surface as the result so the tool can re-check the next hop.
  @Test func disallowConfiguredClientSurfacesRedirectInsteadOfFollowing() async throws {
    // given
    let server = try ScriptedHTTPServer(routes: [
      "/hop": ScriptedResponse(
        status: .movedPermanently,
        headers: [("location", "http://127.0.0.1:1/private")],
        body: ""
      )
    ])
    defer { server.shutdown() }

    // when
    let result = try await withNoRedirectExecutor { executor in
      try await executor.get(
        url: "http://127.0.0.1:\(server.port)/hop",
        headers: [:],
        timeoutSeconds: 5,
        maxBodyBytes: 1024
      )
    }

    // then — the redirect came back to us; nothing fetched the Location target
    #expect(result.statusCode == 301)
    #expect(result.getHeader(for: "Location") == "http://127.0.0.1:1/private")
  }

  @Test func bodyBeyondMaxBodyBytesThrows() async throws {
    // given
    let server = try ScriptedHTTPServer(routes: [
      "/big": ScriptedResponse(status: .ok, headers: [], body: String(repeating: "a", count: 4096))
    ])
    defer { server.shutdown() }

    // when / then
    await #expect(throws: (any Error).self) {
      try await withNoRedirectExecutor { executor in
        _ = try await executor.get(
          url: "http://127.0.0.1:\(server.port)/big",
          headers: [:],
          timeoutSeconds: 5,
          maxBodyBytes: 128
        )
      }
    }
  }
}
