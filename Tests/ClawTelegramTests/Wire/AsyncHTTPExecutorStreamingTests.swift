import AsyncHTTPClient
import ClawCore
import ClawTelegram
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

private actor StreamProbe {
  private var started = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    started = true
    for waiter in startedWaiters {
      waiter.resume()
    }
    startedWaiters.removeAll()
  }

  func waitStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startedWaiters.append(continuation)
    }
  }
}

private final class StreamingHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let probe: StreamProbe
  private let chunkCount: Int

  init(probe: StreamProbe, chunkCount: Int) {
    self.probe = probe
    self.chunkCount = chunkCount
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .end = unwrapInboundIn(data) else {
      return
    }

    let headers = HTTPHeaders([("content-type", "text/event-stream")])
    let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    for chunkIndex in 0..<chunkCount {
      var buffer = context.channel.allocator.buffer(capacity: 32)
      buffer.writeString("data: {\"index\":\(chunkIndex)}\n\n")
      context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }
    context.flush()
    Task { await self.probe.markStarted() }
  }
}

private final class StreamingHTTPServer {
  let group: MultiThreadedEventLoopGroup
  let channel: Channel
  let probe: StreamProbe

  func streamURL() throws -> String {
    let localAddress = try #require(channel.localAddress)
    let port = try #require(localAddress.port)
    return "http://127.0.0.1:\(port)/stream"
  }

  private init(group: MultiThreadedEventLoopGroup, channel: Channel, probe: StreamProbe) {
    self.group = group
    self.channel = channel
    self.probe = probe
  }

  static func start(chunkCount: Int = 1) throws -> StreamingHTTPServer {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let probe = StreamProbe()
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 16)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(StreamingHandler(probe: probe, chunkCount: chunkCount))
        }
      }

    let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    return StreamingHTTPServer(group: group, channel: channel, probe: probe)
  }

  func close() async throws {
    try await channel.close().get()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      group.shutdownGracefully { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

private final class CloseAfterRequestHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .end = unwrapInboundIn(data) else {
      return
    }
    context.close(promise: nil)
  }
}

private final class ClosingHTTPServer {
  let group: MultiThreadedEventLoopGroup
  let channel: Channel

  func url() throws -> String {
    let localAddress = try #require(channel.localAddress)
    let port = try #require(localAddress.port)
    return "http://127.0.0.1:\(port)/stream"
  }

  private init(group: MultiThreadedEventLoopGroup, channel: Channel) {
    self.group = group
    self.channel = channel
  }

  static func start() throws -> ClosingHTTPServer {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 16)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(CloseAfterRequestHandler())
        }
      }

    let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    return ClosingHTTPServer(group: group, channel: channel)
  }

  func close() async throws {
    try await channel.close().get()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      group.shutdownGracefully { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

private func withStreamingHTTPServer<Result>(
  chunkCount: Int = 1,
  _ operation: (StreamingHTTPServer) async throws -> Result
) async throws -> Result {
  let server = try StreamingHTTPServer.start(chunkCount: chunkCount)
  do {
    let result = try await operation(server)
    try await server.close()
    return result
  } catch {
    try? await server.close()
    throw error
  }
}

private func withClosingHTTPServer<Result>(
  _ operation: (ClosingHTTPServer) async throws -> Result
) async throws -> Result {
  let server = try ClosingHTTPServer.start()
  do {
    let result = try await operation(server)
    try await server.close()
    return result
  } catch {
    try? await server.close()
    throw error
  }
}

private func closedLocalPort() async throws -> Int {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 1)
    .childChannelInitializer { channel in
      channel.eventLoop.makeSucceededFuture(())
    }
  let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
  let port = try #require(channel.localAddress?.port)
  try await channel.close().get()
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    group.shutdownGracefully { error in
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume()
      }
    }
  }
  return port
}

private func withHTTPClient<Result>(
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

private enum TimeoutError: Error {
  case timedOut
}

private func withTimeout<Result: Sendable>(
  seconds: UInt64,
  operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
  return try await withThrowingTaskGroup(of: Result.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
      throw TimeoutError.timedOut
    }

    guard let result = try await group.next() else {
      throw TimeoutError.timedOut
    }
    group.cancelAll()
    return result
  }
}

@Suite struct AsyncHTTPExecutorStreamingTests {
  @Test(.timeLimit(.minutes(1)))
  func postStreamYieldsHeadAndBodyChunksWithoutCollecting() async throws {
    // given
    try await withStreamingHTTPServer { server in
      try await withHTTPClient { client in
        let executor = AsyncHTTPExecutor(client: client)

        // when
        let response = try await executor.postStream(
          url: try server.streamURL(),
          headers: [:],
          jsonBody: Data("{}".utf8),
          timeoutSeconds: 5
        )
        var iterator = response.body.makeAsyncIterator()
        let firstChunk = try await iterator.next()
        let firstText = firstChunk.flatMap { String(data: $0, encoding: .utf8) }

        // then
        #expect(response.head.statusCode == 200)
        #expect(firstText?.contains("data:") == true)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellingStreamConsumerTerminatesTheReader() async throws {
    // given
    try await withStreamingHTTPServer { server in
      try await withHTTPClient { client in
        let executor = AsyncHTTPExecutor(client: client)
        let response = try await executor.postStream(
          url: try server.streamURL(),
          headers: [:],
          jsonBody: Data("{}".utf8),
          timeoutSeconds: 30
        )

        // when
        let reader = Task {
          var iterator = response.body.makeAsyncIterator()
          while try await iterator.next() != nil {}
        }
        await server.probe.waitStarted()
        reader.cancel()
        try await withTimeout(seconds: 1) {
          try await reader.value
        }

        // then
        #expect(reader.isCancelled)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func slowStreamConsumerFailsOnBufferOverflow() async throws {
    // given
    try await withStreamingHTTPServer(chunkCount: 128) { server in
      try await withHTTPClient { client in
        let executor = AsyncHTTPExecutor(client: client)
        let response = try await executor.postStream(
          url: try server.streamURL(),
          headers: [:],
          jsonBody: Data("{}".utf8),
          timeoutSeconds: 30
        )

        // when
        await server.probe.waitStarted()
        try await Task.sleep(nanoseconds: 100_000_000)
        let overflowTask = Task<String?, Never> {
          var iterator = response.body.makeAsyncIterator()
          do {
            while try await iterator.next() != nil {}
            return nil
          } catch {
            return String(describing: error)
          }
        }
        let overflowError = try await withTimeout(seconds: 2) {
          await overflowTask.value
        }

        // then
        #expect(overflowError?.contains("buffer overflow") == true)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func connectionFailureBeforeResponseHeadIsConnectFailed() async throws {
    // given
    let port = try await closedLocalPort()
    let configuration = HTTPClient.Configuration(timeout: .init(connect: .milliseconds(100)))
    try await withHTTPClient(configuration: configuration) { client in
      let executor = AsyncHTTPExecutor(client: client)

      // then
      await #expect {
        _ = try await executor.postStream(
          url: "http://127.0.0.1:\(port)/stream",
          headers: [:],
          jsonBody: Data("{}".utf8),
          timeoutSeconds: 1
        )
      } throws: { error in
        guard case ProviderError.connectFailed = error else {
          return false
        }
        return true
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func closeAfterRequestBeforeResponseHeadIsRetryable() async throws {
    // given
    try await withClosingHTTPServer { server in
      let configuration = HTTPClient.Configuration(timeout: .init(connect: .milliseconds(100)))
      try await withHTTPClient(configuration: configuration) { client in
        let executor = AsyncHTTPExecutor(client: client)

        // then
        await #expect {
          _ = try await executor.postStream(
            url: try server.url(),
            headers: [:],
            jsonBody: Data("{}".utf8),
            timeoutSeconds: 1
          )
        } throws: { error in
          guard let providerError = error as? ProviderError else {
            return false
          }
          guard case .retryable(let status, _) = providerError else {
            return false
          }
          return status == nil
        }
      }
    }
  }
}
