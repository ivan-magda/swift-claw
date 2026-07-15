import AsyncHTTPClient
import ClawCore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing

@testable import ClawTelegram

// MARK: - Loopback harness

/// A scripted response for one request path.
struct ScriptedResponse: Sendable {
  let status: HTTPResponseStatus
  let headers: [(String, String)]
  let body: String

  init(status: HTTPResponseStatus, headers: [(String, String)] = [], body: String = "") {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

/// What the server actually saw on the wire, which is the only witness to what the executor sent.
struct ReceivedRequest: Sendable, Equatable {
  let method: String
  let uri: String
  let headers: [String: [String]]
  let body: Data

  func values(for name: String) -> [String] {
    headers[name.lowercased()] ?? []
  }
}

/// Lock-backed rather than an actor so the handler records before it writes the response: by the
/// time a test holds the result, the record is already there and no gate is needed to see it.
final class RequestRecorder: Sendable {
  private let state = Mutex<[ReceivedRequest]>([])

  var received: [ReceivedRequest] {
    state.withLock { current in
      current
    }
  }

  func append(_ request: ReceivedRequest) {
    state.withLock { current in
      current.append(request)
    }
  }
}

/// A minimal HTTP/1.1 server: records each request and answers it with the scripted response for
/// its URI (or 404). Bound to 127.0.0.1 on an ephemeral port.
final class ScriptedHTTPServer: @unchecked Sendable {
  private let group: MultiThreadedEventLoopGroup
  private let channel: Channel
  let recorder: RequestRecorder
  let port: Int

  private init(group: MultiThreadedEventLoopGroup, channel: Channel, recorder: RequestRecorder) {
    self.group = group
    self.channel = channel
    self.recorder = recorder
    port = channel.localAddress?.port ?? 0
  }

  func url(_ path: String) -> String {
    "http://127.0.0.1:\(port)\(path)"
  }

  // Async bind/shutdown only: NIO's blocking `wait()`/`syncShutdownGracefully()` would park a Swift
  // concurrency cooperative thread, and enough of those in flight starve the pool and deadlock the
  // whole run on low-core hosts (CI runners). `get()` and the async `shutdownGracefully` never block.
  static func start(routes: [String: ScriptedResponse]) async throws -> ScriptedHTTPServer {
    let recorder = RequestRecorder()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(ScriptedHandler(routes: routes, recorder: recorder))
        }
      }
    let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    return ScriptedHTTPServer(group: group, channel: channel, recorder: recorder)
  }

  func close() async throws {
    try await channel.close().get()
    try await group.shutdownGracefully()
  }
}

private final class ScriptedHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let routes: [String: ScriptedResponse]
  private let recorder: RequestRecorder
  private var head: HTTPRequestHead?
  private var body = Data()

  init(routes: [String: ScriptedResponse], recorder: RequestRecorder) {
    self.routes = routes
    self.recorder = recorder
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let requestHead):
      head = requestHead
      body = Data()
    case .body(var buffer):
      if let bytes = buffer.readBytes(length: buffer.readableBytes) {
        body.append(contentsOf: bytes)
      }
    case .end:
      guard let requestHead = head else { return }
      var collected: [String: [String]] = [:]
      for header in requestHead.headers {
        collected[header.name.lowercased(), default: []].append(header.value)
      }
      recorder.append(
        ReceivedRequest(
          method: requestHead.method.rawValue,
          uri: requestHead.uri,
          headers: collected,
          body: body
        )
      )
      respond(context: context, uri: requestHead.uri)
    }
  }

  private func respond(context: ChannelHandlerContext, uri: String) {
    let scripted =
      routes[uri] ?? ScriptedResponse(status: .notFound, body: "missing")

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

func withScriptedServer<Result>(
  routes: [String: ScriptedResponse],
  _ operation: (ScriptedHTTPServer) async throws -> Result
) async throws -> Result {
  let server = try await ScriptedHTTPServer.start(routes: routes)
  do {
    let result = try await operation(server)
    try await server.close()
    return result
  } catch {
    try? await server.close()
    throw error
  }
}

/// Accepts and reads a request, then never answers: the only way out is the request deadline.
private final class SilentHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
}

/// Closes the connection the moment a request arrives, so the client loses it before any head.
private final class CloseAfterRequestHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .end = unwrapInboundIn(data) else { return }
    context.close(promise: nil)
  }
}

/// A loopback server whose child pipeline the caller chooses, for the transport edges a scripted
/// response cannot express: a peer that never answers, or one that hangs up before the head.
final class BehaviourHTTPServer: @unchecked Sendable {
  enum Behaviour: Sendable {
    case neverResponds
    case closesBeforeHead
  }

  private let group: MultiThreadedEventLoopGroup
  private let channel: Channel
  let port: Int

  private init(group: MultiThreadedEventLoopGroup, channel: Channel) {
    self.group = group
    self.channel = channel
    port = channel.localAddress?.port ?? 0
  }

  func url(_ path: String) -> String {
    "http://127.0.0.1:\(port)\(path)"
  }

  static func start(behaviour: Behaviour) async throws -> BehaviourHTTPServer {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 16)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          switch behaviour {
          case .neverResponds:
            return channel.pipeline.addHandler(SilentHandler())
          case .closesBeforeHead:
            return channel.pipeline.addHandler(CloseAfterRequestHandler())
          }
        }
      }
    let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    return BehaviourHTTPServer(group: group, channel: channel)
  }

  func close() async throws {
    try await channel.close().get()
    try await group.shutdownGracefully()
  }
}

func withBehaviourServer<Result>(
  _ behaviour: BehaviourHTTPServer.Behaviour,
  _ operation: (BehaviourHTTPServer) async throws -> Result
) async throws -> Result {
  let server = try await BehaviourHTTPServer.start(behaviour: behaviour)
  do {
    let result = try await operation(server)
    try await server.close()
    return result
  } catch {
    try? await server.close()
    throw error
  }
}

/// A port nothing listens on, so a connect to it is refused rather than merely unanswered.
func closedLocalPort() async throws -> Int {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 1)
    .childChannelInitializer { channel in
      channel.eventLoop.makeSucceededFuture(())
    }
  let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
  let port = channel.localAddress?.port ?? 0
  try await channel.close().get()
  try await group.shutdownGracefully()
  return port
}

/// `HTTPClient.syncShutdown()` is unavailable from async contexts and a `defer` cannot `await`; this
/// guarantees `shutdown()` on every exit path (AHC's `deinit` precondition-fails in debug builds if
/// a client is dropped un-shut-down).
func withHTTPClient<Result>(
  configuration: HTTPClient.Configuration = HTTPClient.Configuration(),
  _ operation: (HTTPClient) async throws -> Result
) async throws -> Result {
  let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  do {
    let result = try await operation(client)
    try await client.shutdown()
    return result
  } catch {
    try? await client.shutdown()
    throw error
  }
}

func withExecutor<Result>(
  configuration: HTTPClient.Configuration = HTTPClient.Configuration(),
  _ operation: (AsyncHTTPExecutor) async throws -> Result
) async throws -> Result {
  try await withHTTPClient(configuration: configuration) { client in
    try await operation(AsyncHTTPExecutor(client: client))
  }
}

/// A handoff refusal a test can recognise by identity, standing in for the caller's own typed
/// refusal when its exposure ledger has already observed cancellation.
struct HandoffRefusal: Error, Equatable {}

/// Counts handoff invocations, because "exactly once" is the property under test and a boolean
/// could not tell one call from two.
final class HandoffCounter: Sendable {
  private let count = Mutex(0)

  var value: Int {
    count.withLock { current in
      current
    }
  }

  /// A handoff that lets the attempt through.
  var callback: @Sendable () throws -> Void {
    { [self] in
      record()
    }
  }

  /// A handoff that refuses the attempt, as a caller's ledger does when it has already observed
  /// cancellation.
  var refusingCallback: @Sendable () throws -> Void {
    { [self] in
      record()
      throw HandoffRefusal()
    }
  }

  private func record() {
    count.withLock { current in
      current += 1
    }
  }
}

// MARK: - Tests

@Suite(.serialized) struct AsyncHTTPExecutorGeneralRequestTests {
  private func buffered(
    successBytes: Int = 1024 * 1024,
    errorBytes: Int = 1024 * 1024
  ) -> HTTPResponseBodyPolicy {
    .buffered(successBytes: successBytes, errorBytes: errorBytes)
  }

  @Test(.timeLimit(.minutes(1)))
  func getCarriesMethodAndHeadersAndReturnsTheBody() async throws {
    // given
    try await withScriptedServer(routes: [
      "/page": ScriptedResponse(
        status: .ok,
        headers: [("content-type", "text/html")],
        body: "<html>hello</html>"
      )
    ]) { server in
      // when
      let result = try await withExecutor { executor in
        try await executor.execute(
          HTTPRequest(
            method: .get,
            url: server.url("/page"),
            headers: ["X-Probe": "probe-value"],
            body: nil,
            timeoutSeconds: 5,
            responseBodyPolicy: buffered()
          )
        )
      }

      // then
      let received = try #require(server.recorder.received.first)
      #expect(received.method == "GET")
      #expect(received.uri == "/page")
      #expect(received.values(for: "X-Probe") == ["probe-value"])
      #expect(result.statusCode == 200)
      #expect(result.getHeader(for: "Content-Type") == "text/html")
      #expect(String(data: result.body, encoding: .utf8) == "<html>hello</html>")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func jsonPostConvenienceSendsTheBodyUnderOneContentType() async throws {
    // given
    let payload = Data(#"{"hello":"world"}"#.utf8)
    try await withScriptedServer(routes: [
      "/rpc": ScriptedResponse(status: .ok, body: "{}")
    ]) { server in
      // when
      _ = try await withExecutor { executor in
        try await executor.post(
          url: server.url("/rpc"),
          headers: ["X-Probe": "probe-value"],
          jsonBody: payload,
          timeoutSeconds: 5
        )
      }

      // then
      let received = try #require(server.recorder.received.first)
      #expect(received.method == "POST")
      #expect(received.body == payload)
      #expect(received.values(for: "content-type") == ["application/json"])
      #expect(received.values(for: "X-Probe") == ["probe-value"])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func rawFormPostKeepsTheCallersContentTypeAsTheOnlyOne() async throws {
    // given — the shape an OAuth token exchange needs: a form body, not JSON
    let form = Data("grant_type=refresh_token&refresh_token=abc".utf8)
    try await withScriptedServer(routes: [
      "/token": ScriptedResponse(status: .ok, body: "{}")
    ]) { server in
      // when
      _ = try await withExecutor { executor in
        try await executor.execute(
          HTTPRequest(
            method: .post,
            url: server.url("/token"),
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: form,
            timeoutSeconds: 5,
            responseBodyPolicy: buffered()
          )
        )
      }

      // then — one content-type, the caller's; a duplicated field would be a protocol error
      let received = try #require(server.recorder.received.first)
      #expect(received.body == form)
      #expect(received.values(for: "content-type") == ["application/x-www-form-urlencoded"])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func successBodyBeyondTheSuccessCapFailsRatherThanArrivingShort() async throws {
    // given
    try await withScriptedServer(routes: [
      "/big": ScriptedResponse(status: .ok, body: String(repeating: "a", count: 4096))
    ]) { server in
      // when
      let failure = await #expect(throws: HTTPTransportFailure.self) {
        try await withExecutor { executor in
          try await executor.execute(
            HTTPRequest(
              method: .get,
              url: server.url("/big"),
              headers: [:],
              body: nil,
              timeoutSeconds: 5,
              responseBodyPolicy: buffered(successBytes: 128, errorBytes: 4096)
            )
          )
        }
      }

      // then — handing back the first 128 bytes would be indistinguishable from a whole payload, so
      // the over-cap 2xx is reported as the malformed response it is, naming the cap it stopped at
      #expect(failure?.disposition == .mayHaveBeenSent)
      #expect(failure?.safeMessage.contains("128") == true)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func successBodyExactlyAtTheSuccessCapIsDeliveredWhole() async throws {
    // given
    try await withScriptedServer(routes: [
      "/exact": ScriptedResponse(status: .ok, body: String(repeating: "a", count: 128))
    ]) { server in
      // when
      let result = try await withExecutor { executor in
        try await executor.execute(
          HTTPRequest(
            method: .get,
            url: server.url("/exact"),
            headers: [:],
            body: nil,
            timeoutSeconds: 5,
            responseBodyPolicy: buffered(successBytes: 128, errorBytes: 4096)
          )
        )
      }

      // then — the cap is a limit, not a threshold: a body that fits is whole and passes
      #expect(result.statusCode == 200)
      #expect(result.body.count == 128)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func errorBodyStopsAtTheErrorCap() async throws {
    // given
    try await withScriptedServer(routes: [
      "/boom": ScriptedResponse(
        status: .internalServerError,
        body: String(repeating: "b", count: 4096)
      )
    ]) { server in
      // when
      let result = try await withExecutor { executor in
        try await executor.execute(
          HTTPRequest(
            method: .get,
            url: server.url("/boom"),
            headers: [:],
            body: nil,
            timeoutSeconds: 5,
            responseBodyPolicy: buffered(successBytes: 4096, errorBytes: 64)
          )
        )
      }

      // then — a diagnostic is worth only its own allowance, whatever the success cap permits
      #expect(result.statusCode == 500)
      #expect(result.body.count == 64)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func redirectIsSurfacedAndCappedByTheErrorAllowance() async throws {
    // given — SSRF policy requires the 3xx come back rather than be followed
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    try await withScriptedServer(routes: [
      "/hop": ScriptedResponse(
        status: .movedPermanently,
        headers: [("location", "http://127.0.0.1:1/private")],
        body: String(repeating: "c", count: 512)
      )
    ]) { server in
      // when
      let result = try await withExecutor(configuration: configuration) { executor in
        try await executor.execute(
          HTTPRequest(
            method: .get,
            url: server.url("/hop"),
            headers: [:],
            body: nil,
            timeoutSeconds: 5,
            responseBodyPolicy: buffered(successBytes: 512, errorBytes: 32)
          )
        )
      }

      // then — nothing fetched the Location target, and a 3xx is not a success for cap purposes
      #expect(result.statusCode == 301)
      #expect(result.getHeader(for: "Location") == "http://127.0.0.1:1/private")
      #expect(result.body.count == 32)
      #expect(server.recorder.received.count == 1)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func executeRejectsAStreamingPolicyWithoutSending() async throws {
    // given
    let routes = ["/rpc": ScriptedResponse(status: .ok, body: "{}")]
    try await withScriptedServer(routes: routes) { server in
      // when
      let failure = await #expect(throws: HTTPTransportFailure.self) {
        try await withExecutor { executor in
          try await executor.execute(
            HTTPRequest(
              method: .post,
              url: server.url("/rpc"),
              headers: [:],
              body: Data("{}".utf8),
              timeoutSeconds: 5,
              responseBodyPolicy: .streaming(maximumUnreadBytes: 1024, errorBytes: 1024)
            )
          )
        }
      }

      // then — caught before the handoff, so nothing could have reached the wire
      #expect(failure?.disposition == .definitelyNotSent)
      #expect(server.recorder.received.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func openStreamRejectsABufferedPolicyWithoutSending() async throws {
    // given
    let routes = ["/rpc": ScriptedResponse(status: .ok, body: "{}")]
    try await withScriptedServer(routes: routes) { server in
      // when
      let failure = await #expect(throws: HTTPTransportFailure.self) {
        try await withExecutor { executor in
          try await executor.openStream(
            HTTPRequest(
              method: .post,
              url: server.url("/rpc"),
              headers: [:],
              body: Data("{}".utf8),
              timeoutSeconds: 5,
              responseBodyPolicy: buffered()
            )
          )
        }
      }

      // then
      #expect(failure?.disposition == .definitelyNotSent)
      #expect(server.recorder.received.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func handoffRunsExactlyOnceBeforeABufferedSubmission() async throws {
    // given
    let counter = HandoffCounter()
    let routes = ["/rpc": ScriptedResponse(status: .ok, body: "{}")]
    try await withScriptedServer(routes: routes) { server in
      // when
      _ = try await withExecutor { executor in
        try await executor.execute(
          HTTPRequest(
            method: .post,
            url: server.url("/rpc"),
            headers: [:],
            body: Data("{}".utf8),
            timeoutSeconds: 5,
            responseBodyPolicy: buffered(),
            beginHandoff: counter.callback
          )
        )
      }

      // then — one handoff, one request: the linearization point matches what the wire saw
      #expect(counter.value == 1)
      #expect(server.recorder.received.count == 1)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func handoffRefusalPreventsABufferedSubmission() async throws {
    // given — the caller's ledger has already observed cancellation and refuses the attempt
    let counter = HandoffCounter()
    let routes = ["/rpc": ScriptedResponse(status: .ok, body: "{}")]
    try await withScriptedServer(routes: routes) { server in
      // when
      await #expect(throws: HandoffRefusal.self) {
        try await withExecutor { executor in
          try await executor.execute(
            HTTPRequest(
              method: .post,
              url: server.url("/rpc"),
              headers: [:],
              body: Data("{}".utf8),
              timeoutSeconds: 5,
              responseBodyPolicy: buffered(),
              beginHandoff: counter.refusingCallback
            )
          )
        }
      }

      // then — the refusal comes back untouched and nothing was sent
      #expect(counter.value == 1)
      #expect(server.recorder.received.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func refusedConnectionIsDefinitelyNotSent() async throws {
    // given — nothing is listening, so no channel to write a request on ever exists
    let port = try await closedLocalPort()
    var configuration = HTTPClient.Configuration()
    configuration.timeout = .init(connect: .milliseconds(10))

    // when
    let failure = await #expect(throws: HTTPTransportFailure.self) {
      try await withExecutor(configuration: configuration) { executor in
        try await executor.execute(
          HTTPRequest(
            method: .post,
            url: "http://127.0.0.1:\(port)/rpc",
            headers: [:],
            body: Data("{}".utf8),
            timeoutSeconds: 1,
            responseBodyPolicy: buffered()
          )
        )
      }
    }

    // then
    #expect(failure?.disposition == .definitelyNotSent)
  }

  @Test(.timeLimit(.minutes(1)))
  func closeBeforeHeadIsMayHaveBeenSent() async throws {
    // given — the peer took the request and hung up; whether it acted on it is unknowable
    try await withBehaviourServer(.closesBeforeHead) { server in
      // when
      let failure = await #expect(throws: HTTPTransportFailure.self) {
        try await withExecutor { executor in
          try await executor.execute(
            HTTPRequest(
              method: .post,
              url: server.url("/rpc"),
              headers: [:],
              body: Data("{}".utf8),
              timeoutSeconds: 5,
              responseBodyPolicy: buffered()
            )
          )
        }
      }

      // then — an unknown pre-head failure never claims to be clean
      #expect(failure?.disposition == .mayHaveBeenSent)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func requestTimeoutAppliesAndIsMayHaveBeenSent() async throws {
    // given — the peer reads the request and never answers, so only the deadline ends the call
    try await withBehaviourServer(.neverResponds) { server in
      // when
      let started = ContinuousClock.now
      let failure = await #expect(throws: HTTPTransportFailure.self) {
        try await withExecutor { executor in
          try await executor.execute(
            HTTPRequest(
              method: .post,
              url: server.url("/rpc"),
              headers: [:],
              body: Data("{}".utf8),
              timeoutSeconds: 1,
              responseBodyPolicy: buffered()
            )
          )
        }
      }
      let elapsed = ContinuousClock.now - started

      // then — the deadline that fired is the request's own one second, not some larger default a
      // bare "it failed eventually" would have accepted just as happily
      #expect(elapsed < .seconds(5))
      #expect(failure?.disposition == .mayHaveBeenSent)
    }
  }
}

// MARK: - Classification tests

/// The disposition rules driven directly. A response head is what separates the two classifiers, and
/// no loopback peer can raise a connection-refused while a body is already arriving — the one error
/// that would prove the distinction — so the functions themselves are the honest witness here.
@Suite struct AsyncHTTPExecutorClassificationTests {
  @Test
  func connectionRefusedBeforeAnyHeadIsTheSoleProofOfACleanRequest() {
    // given — the transport typed the failure as a refusal: no channel to write a request on existed
    let refused = IOError(errnoCode: ECONNREFUSED, reason: "connection refused")

    // when
    let failure = AsyncHTTPExecutor.classify(refused)

    // then
    #expect(failure.disposition == .definitelyNotSent)
  }

  @Test
  func aResponseHeadRulesOutEveryCleanClaimForWhatFollowsIt() {
    // given — the very error the pre-head allowlist accepts as proof nothing was written
    let refused = IOError(errnoCode: ECONNREFUSED, reason: "connection refused")

    // when — the same error, classified on either side of a response head
    let beforeHead = AsyncHTTPExecutor.classify(refused)
    let afterHead = AsyncHTTPExecutor.classifyPostHead(refused)

    // then — a head proves the channel existed and was written, so the allowlist's premise cannot
    // hold once one has arrived: replaying such a turn would re-bill tokens already generated
    #expect(beforeHead.disposition == .definitelyNotSent)
    #expect(afterHead.disposition == .mayHaveBeenSent)
  }

  @Test
  func connectTimeoutIsNeverCleanSoItCannotBeReplayed() {
    // given — a connect that timed out: the SYN may have landed and only its answer been lost
    let timedOut = HTTPClientError.connectTimeout

    // when
    let failure = AsyncHTTPExecutor.classify(timedOut)

    // then — narrowing the allowlist to a typed refusal is what costs this its clean claim, and with
    // it the stream-to-buffered replay a `definitelyNotSent` would have licensed
    #expect(failure.disposition == .mayHaveBeenSent)
  }
}
