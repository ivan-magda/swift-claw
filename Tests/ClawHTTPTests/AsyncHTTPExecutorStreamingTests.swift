import AsyncHTTPClient
import ClawCore
import ClawTestSupport
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing

@testable import ClawHTTP

// MARK: - Streaming loopback server

/// Writes a head and a burst of chunks, then ends the response. The gate opens once the last write
/// has actually left, so a test can wait for the whole burst to be in flight instead of guessing.
private final class BurstingHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let written: AsyncGate
  private let chunkCount: Int
  private let chunkBytes: Int

  init(written: AsyncGate, chunkCount: Int, chunkBytes: Int) {
    self.written = written
    self.chunkCount = chunkCount
    self.chunkBytes = chunkBytes
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .end = unwrapInboundIn(data) else { return }

    let headers = HTTPHeaders([("content-type", "text/event-stream")])
    context.write(
      wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))),
      promise: nil
    )
    for chunkIndex in 0..<chunkCount {
      var buffer = context.channel.allocator.buffer(capacity: chunkBytes)
      buffer.writeString(BurstingServer.chunkText(index: chunkIndex, bytes: chunkBytes))
      context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }
    let finalWrite = context.eventLoop.makePromise(of: Void.self)
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: finalWrite)
    finalWrite.futureResult.whenComplete { [written] _ in
      written.open()
    }
  }
}

private final class BurstingServer: @unchecked Sendable {
  private let group: MultiThreadedEventLoopGroup
  private let channel: Channel
  let written: AsyncGate
  let port: Int

  /// Chunks are fixed width so a test can state the expected transfer exactly, and carry their index
  /// so a dropped or reordered one shows up as a mismatch rather than a byte count that still adds up.
  static func chunkText(index: Int, bytes: Int) -> String {
    let marker = "data:\(index);"
    return marker.count >= bytes
      ? String(marker.prefix(bytes))
      : marker + String(repeating: "-", count: bytes - marker.count)
  }

  static func expectedBody(chunkCount: Int, chunkBytes: Int) -> Data {
    Data(
      (0..<chunkCount).map { index in
        chunkText(index: index, bytes: chunkBytes)
      }
      .joined()
      .utf8
    )
  }

  private init(group: MultiThreadedEventLoopGroup, channel: Channel, written: AsyncGate) {
    self.group = group
    self.channel = channel
    self.written = written
    port = channel.localAddress?.port ?? 0
  }

  func url() -> String {
    "http://127.0.0.1:\(port)/stream"
  }

  static func start(chunkCount: Int, chunkBytes: Int) async throws -> BurstingServer {
    let written = AsyncGate()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 16)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(
            BurstingHandler(written: written, chunkCount: chunkCount, chunkBytes: chunkBytes)
          )
        }
      }
    let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    return BurstingServer(group: group, channel: channel, written: written)
  }

  func close() async throws {
    try await channel.close().get()
    try await group.shutdownGracefully()
  }
}

private func withBurstingServer<Result>(
  chunkCount: Int = 1,
  chunkBytes: Int = 24,
  _ operation: (BurstingServer) async throws -> Result
) async throws -> Result {
  let server = try await BurstingServer.start(chunkCount: chunkCount, chunkBytes: chunkBytes)
  do {
    let result = try await operation(server)
    try await server.close()
    return result
  } catch {
    try? await server.close()
    throw error
  }
}

// MARK: - Executor streaming tests

@Suite(.serialized) struct AsyncHTTPExecutorStreamingTests {
  private func streaming(
    maximumUnreadBytes: Int = 4 * 1024 * 1024,
    errorBytes: Int = 64 * 1024
  ) -> HTTPResponseBodyPolicy {
    .streaming(maximumUnreadBytes: maximumUnreadBytes, errorBytes: errorBytes)
  }

  private func streamRequest(
    url: String,
    policy: HTTPResponseBodyPolicy,
    timeoutSeconds: Int = 30,
    beginHandoff: (@Sendable () throws -> Void)? = nil
  ) -> HTTPRequest {
    HTTPRequest(
      method: .post,
      url: url,
      headers: [:],
      body: Data("{}".utf8),
      timeout: .seconds(timeoutSeconds),
      responseBodyPolicy: policy,
      beginHandoff: beginHandoff
    )
  }

  @Test(.timeLimit(.minutes(1)))
  func openStreamYieldsTheHeadThenEveryChunk() async throws {
    // given
    try await withBurstingServer(chunkCount: 4) { server in
      try await withExecutor { executor in
        // when
        let exchange = try await executor.openStream(
          streamRequest(url: server.url(), policy: streaming())
        )
        var collected = Data()
        for try await chunk in exchange.body {
          collected.append(chunk)
        }
        let termination = await exchange.awaitTermination()

        // then
        #expect(exchange.head.statusCode == 200)
        #expect(exchange.head.getHeader(for: "Content-Type") == "text/event-stream")
        #expect(collected == BurstingServer.expectedBody(chunkCount: 4, chunkBytes: 24))
        #expect(termination == .completed)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func slowConsumerBehindATinyUnreadCapStillReceivesEveryByte() async throws {
    // given — an unread allowance far smaller than the burst, so the producer must suspend repeatedly
    let chunkCount = 128
    let chunkBytes = 24
    try await withBurstingServer(chunkCount: chunkCount, chunkBytes: chunkBytes) { server in
      try await withExecutor { executor in
        let exchange = try await executor.openStream(
          // Room for a handful of chunks against a burst of 128: enough to force the producer to
          // park over and over, loose enough not to rest on exactly how the transport frames them.
          streamRequest(url: server.url(), policy: streaming(maximumUnreadBytes: chunkBytes * 4))
        )

        // when — the whole burst is on the wire before a single chunk is read
        await server.written.wait()
        var collected = Data()
        for try await chunk in exchange.body {
          collected.append(chunk)
        }
        let termination = await exchange.awaitTermination()

        // then — bounding the queue suspends the producer; it never costs a byte
        #expect(
          collected == BurstingServer.expectedBody(chunkCount: chunkCount, chunkBytes: chunkBytes)
        )
        #expect(termination == .completed)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func chunkLargerThanTheWholeUnreadCapFailsTheExchange() async throws {
    // given — a chunk no amount of draining could ever admit
    try await withBurstingServer(chunkCount: 1, chunkBytes: 64) { server in
      try await withExecutor { executor in
        let exchange = try await executor.openStream(
          streamRequest(url: server.url(), policy: streaming(maximumUnreadBytes: 8))
        )

        // when
        var collected = Data()
        let thrown = await #expect(throws: HTTPTransportFailure.self) {
          for try await chunk in exchange.body {
            collected.append(chunk)
          }
        }
        let termination = await exchange.awaitTermination()

        // then — the transfer fails rather than parking forever, and says so to a joiner
        #expect(collected.isEmpty)
        #expect(thrown?.disposition == .mayHaveBeenSent)
        #expect(termination == .failed(try #require(thrown)))
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func nonSuccessStreamBodyIsCappedAtTheErrorAllowance() async throws {
    // given
    try await withScriptedServer(routes: [
      "/stream": ScriptedResponse(
        status: .tooManyRequests,
        body: String(repeating: "e", count: 4096)
      )
    ]) { server in
      try await withExecutor { executor in
        // when
        let exchange = try await executor.openStream(
          streamRequest(
            url: server.url("/stream"),
            policy: streaming(maximumUnreadBytes: 4 * 1024 * 1024, errorBytes: 100)
          )
        )
        var collected = Data()
        for try await chunk in exchange.body {
          collected.append(chunk)
        }
        let termination = await exchange.awaitTermination()

        // then — a diagnostic body is read whole, and the whole of it is what the cap bounds
        #expect(exchange.head.statusCode == 429)
        #expect(collected.count == 100)
        #expect(termination == .completed)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func handoffRunsExactlyOnceBeforeAStreamingSubmission() async throws {
    // given
    let counter = HandoffCounter()
    try await withBurstingServer(chunkCount: 1) { server in
      try await withExecutor { executor in
        // when
        let exchange = try await executor.openStream(
          streamRequest(url: server.url(), policy: streaming(), beginHandoff: counter.callback)
        )
        for try await _ in exchange.body {}
        _ = await exchange.awaitTermination()

        // then — reading the body must not re-run the linearization point
        #expect(counter.value == 1)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func handoffRefusalPreventsAStreamingSubmission() async throws {
    // given
    let counter = HandoffCounter()
    let routes = ["/stream": ScriptedResponse(status: .ok, body: "x")]
    try await withScriptedServer(routes: routes) { server in
      // when
      await #expect(throws: HandoffRefusal.self) {
        try await withExecutor { executor in
          _ = try await executor.openStream(
            streamRequest(
              url: server.url("/stream"),
              policy: streaming(),
              beginHandoff: counter.refusingCallback
            )
          )
        }
      }

      // then
      #expect(counter.value == 1)
      #expect(server.recorder.received.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func refusedConnectionBeforeHeadIsDefinitelyNotSent() async throws {
    // given
    let port = try await closedLocalPort()
    var configuration = HTTPClient.Configuration()
    // Network.framework parks a refused connect as "waiting" rather than failing it, so this bound is
    // what ends the wait and surfaces the typed refusal. It clears the ~1-2ms the transport takes to
    // record that refusal by two orders of magnitude, so a loaded machine cannot make the deadline
    // land first and yield an untyped connect timeout instead.
    configuration.timeout = .init(connect: .milliseconds(200))

    // when
    let failure = await #expect(throws: HTTPTransportFailure.self) {
      try await withExecutor(configuration: configuration) { executor in
        _ = try await executor.openStream(
          streamRequest(
            url: "http://127.0.0.1:\(port)/stream",
            policy: streaming(),
            timeoutSeconds: 1
          )
        )
      }
    }

    // then
    #expect(failure?.disposition == .definitelyNotSent)
  }

  @Test(.timeLimit(.minutes(1)))
  func closeBeforeHeadIsMayHaveBeenSent() async throws {
    // given
    try await withBehaviourServer(.closesBeforeHead) { server in
      // when
      let failure = await #expect(throws: HTTPTransportFailure.self) {
        try await withExecutor { executor in
          _ = try await executor.openStream(
            streamRequest(url: server.url("/stream"), policy: streaming(), timeoutSeconds: 5)
          )
        }
      }

      // then
      #expect(failure?.disposition == .mayHaveBeenSent)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellingAnExchangeJoinsItPromptly() async throws {
    // given — 3072 bytes of burst against a 48-byte unread window: the server does end the response,
    // but it cannot outrun that window, so the producer is guaranteed parked mid-transfer below
    try await withBurstingServer(chunkCount: 128) { server in
      try await withExecutor { executor in
        let exchange = try await executor.openStream(
          streamRequest(url: server.url(), policy: streaming(maximumUnreadBytes: 48))
        )
        var iterator = exchange.body.makeAsyncIterator()
        _ = try await iterator.next()

        // when
        let termination = await exchange.cancelAndAwait()

        // then
        #expect(termination == .cancelled(.mayHaveBeenSent))
      }
    }
  }
}

// MARK: - Exchange ownership tests

/// The ownership rules exercised directly, where a producer's exit can be driven rather than raced:
/// the transport tests above prove the executor builds an exchange, these prove what an exchange
/// promises whoever joins it.
@Suite(.serialized) struct HTTPStreamExchangeOwnershipTests {
  private let head = HTTPStreamHead(statusCode: 200, headers: [:])

  @Test(.timeLimit(.minutes(1)))
  func joinReturnsOnlyAfterTheProducerHasExited() async throws {
    // given
    let started = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let hasExited = Mutex(false)
    let exchange = HTTPStreamExchange.make(head: head, maximumUnreadBodyBytes: 64) { _ in
      started.open()
      await release.waitIgnoringCancellation()
      hasExited.withLock { current in
        current = true
      }
      return .completed
    }

    // when
    let joiner = Task {
      await exchange.awaitTermination()
    }
    await started.wait()
    release.open()
    let termination = await joiner.value

    // then — the join cannot report an outcome the producer has not reached yet
    #expect(hasExited.withLock { current in current })
    #expect(termination == .completed)
  }

  @Test(.timeLimit(.minutes(1)))
  func repeatedJoinsReturnTheSameCachedTermination() async throws {
    // given
    let failure = HTTPTransportFailure(disposition: .mayHaveBeenSent, safeMessage: "gone")
    let exchange = HTTPStreamExchange.make(head: head, maximumUnreadBodyBytes: 64) { _ in
      .failed(failure)
    }

    // when
    let first = await exchange.awaitTermination()
    let second = await exchange.awaitTermination()
    let third = await exchange.cancelAndAwait()

    // then — one outcome, however many times it is asked for
    #expect(first == .failed(failure))
    #expect(second == first)
    #expect(third == first)
  }

  @Test(.timeLimit(.minutes(1)))
  func joinIgnoresTheJoinersOwnCancellation() async throws {
    // given
    let release = AsyncGate()
    defer { release.open() }
    let exchange = HTTPStreamExchange.make(head: head, maximumUnreadBodyBytes: 64) { _ in
      await release.waitIgnoringCancellation()
      return .completed
    }

    // when — the joiner is cancelled while the producer is still working
    let joiner = Task {
      await exchange.awaitTermination()
    }
    joiner.cancel()
    release.open()
    let termination = await joiner.value

    // then — a join reports what the producer did, never the joiner's own cancellation
    #expect(termination == .completed)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelWakesAProducerSuspendedOnAFullBuffer() async throws {
    // given — capacity for one chunk and no consumer, so the second send has nowhere to go
    let filled = AsyncGate()
    let exchange = HTTPStreamExchange.make(head: head, maximumUnreadBodyBytes: 4) { sink in
      do {
        try await sink.send(Data(repeating: 0x61, count: 4))
        filled.open()
        try await sink.send(Data(repeating: 0x62, count: 4))
        return .completed
      } catch {
        return .cancelled(.mayHaveBeenSent)
      }
    }

    // when — yielding drives the producer to its suspension point rather than waiting on a clock
    await filled.wait()
    for _ in 0..<10 {
      await Task.yield()
    }
    let termination = await exchange.cancelAndAwait()

    // then — a producer parked on a full buffer is woken, not stranded: no consumer ever read
    #expect(termination == .cancelled(.mayHaveBeenSent))
  }

  @Test(.timeLimit(.minutes(1)))
  func abandoningTheBodyIterationCancelsTheExchange() async throws {
    // given — an endless producer that only a cancellation can stop
    let exchange = HTTPStreamExchange.make(head: head, maximumUnreadBodyBytes: 8) { sink in
      do {
        while true {
          try await sink.send(Data(repeating: 0x63, count: 4))
        }
      } catch {
        return .cancelled(.mayHaveBeenSent)
      }
    }

    // when — the consumer takes one chunk and walks away, dropping the iterator
    for try await _ in exchange.body {
      break
    }
    let termination = await exchange.awaitTermination()

    // then — the abandoned iteration stopped the work behind it, and the join still reports it
    #expect(termination == .cancelled(.mayHaveBeenSent))
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellationMidTransferKeepsChunksTheConsumerWasAlreadyOwed() async throws {
    // given — a producer still working, with a delivered chunk sitting unread behind it
    let delivered = AsyncGate()
    let release = AsyncGate()
    defer { release.open() }
    let exchange = HTTPStreamExchange.make(head: head, maximumUnreadBodyBytes: 64) { sink in
      do {
        try await sink.send(Data("first".utf8))
        delivered.open()
        await release.waitIgnoringCancellation()
        try await sink.send(Data("second".utf8))
        return .completed
      } catch {
        return .cancelled(.mayHaveBeenSent)
      }
    }
    await delivered.wait()

    // when — cancelled with the transfer in flight, not after it had already run to completion
    exchange.cancel()
    release.open()
    let termination = await exchange.awaitTermination()
    var collected = Data()
    for try await chunk in exchange.body {
      collected.append(chunk)
    }

    // then — closing bounds the producer; it does not discard what the consumer was already owed,
    // and the chunk the cancellation cut off never arrives
    #expect(collected == Data("first".utf8))
    #expect(termination == .cancelled(.mayHaveBeenSent))
  }
}
