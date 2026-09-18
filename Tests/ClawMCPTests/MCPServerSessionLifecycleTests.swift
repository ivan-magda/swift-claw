import ClawCore
import ClawTestSupport
import Foundation
import Logging
import MCP
import Testing

@testable import ClawMCP

@Suite("MCP session lifecycle")
struct MCPServerSessionLifecycleTests {
  @Test("handshake cleanup cancels the SDK receiver before waiting for transport teardown")
  func handshakeCleanupCancelsReceiver() async throws {
    // given
    let transport = GatedReceiveTransport()
    defer { transport.release.open() }
    let session = MCPServerSession(
      config: try MCPServerConfig(name: "fixture", url: "https://mcp.example.com/mcp"),
      transportFactory: StubTransportFactory {
        transport
      },
      clientVersion: "0.0.0-test",
      logger: transport.logger
    )
    let opening = Task {
      try await session.connect()
    }
    #expect(await transport.receiving.waitUntilOpen())

    // when
    let closing = Task {
      await session.disconnect()
    }
    let cleanupStarted = await transport.cleaningUp.waitUntilOpen()
    let receiverCancelled = await transport.receiverCancelledOnDisconnect
    transport.release.open()
    await closing.value
    _ = await opening.result

    // then
    #expect(cleanupStarted)
    #expect(receiverCancelled)
  }

  @Test("disconnect forwards cancellation into an SDK handshake already awaiting transport")
  func disconnectDuringHandshake() async throws {
    // given
    let server = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
    let transport = GatedHandshakeTransport(wrapping: try await server.makeTransport())
    defer { transport.release.open() }
    let session = MCPServerSession(
      config: try MCPServerConfig(name: "fixture", url: "https://mcp.example.com/mcp"),
      transportFactory: StubTransportFactory {
        transport
      },
      clientVersion: "0.0.0-test",
      logger: Logger(label: "test.silent") { _ in
        SwiftLogNoOpLogHandler()
      }
    )
    let opening = Task {
      try await session.connect()
    }
    #expect(await transport.entered.waitUntilOpen())

    // when
    let closing = Task {
      await session.disconnect()
    }
    let cancelled = await transport.cancelled.waitUntilOpen()
    transport.release.open()
    await closing.value
    let joined = transport.finished.isOpen
    let result = await opening.result
    await session.disconnect()
    await server.stop()

    // then
    #expect(cancelled)
    #expect(joined)
    switch result {
    case .success:
      Issue.record("The SDK handshake completed after disconnect had cancelled it")
    case .failure(let error):
      #expect(error is CancellationError)
    }
  }

  @Test("disconnect cancels and joins an opening before a later call reconnects")
  func disconnectDuringOpening() async throws {
    // given
    let openingStarted = AsyncGate()
    let openingCancelled = AsyncGate()
    let allowOpening = AsyncGate()
    defer { allowOpening.open() }
    let server = ScriptedMCPServer(list: ScriptedMCPServer.paged([[]]))
    let session = MCPServerSession(
      config: try MCPServerConfig(name: "fixture", url: "https://mcp.example.com/mcp"),
      transportFactory: StubTransportFactory {
        let transport = try await server.makeTransport()
        if await server.connections == 1 {
          openingStarted.open()
          await withTaskCancellationHandler(
            operation: {
              await allowOpening.waitIgnoringCancellation()
            },
            onCancel: {
              openingCancelled.open()
            }
          )
        }
        return transport
      },
      clientVersion: "0.0.0-test",
      logger: Logger(label: "test.silent") { _ in
        SwiftLogNoOpLogHandler()
      }
    )
    let opening = Task {
      try await session.connect()
    }
    #expect(await openingStarted.waitUntilOpen())

    // when
    let closing = Task {
      await session.disconnect()
    }
    let cancelled = await openingCancelled.waitUntilOpen()
    allowOpening.open()
    let result = await opening.result
    await closing.value
    let fresh = try? await session.callTool(name: "fresh", arguments: [:])
    await session.disconnect()
    await server.stop()

    // then
    #expect(cancelled)
    switch result {
    case .success:
      Issue.record("The opening completed after disconnect had cancelled it")
    case .failure(let error):
      #expect(error is CancellationError)
    }
    let expected: [MCP.Tool.Content] = [
      .text(text: "fresh on connection 2", annotations: nil, _meta: nil),
    ]
    #expect(fresh?.content == expected)
  }
}

private actor GatedReceiveTransport: Transport {
  nonisolated let logger = Logger(label: "test.silent") { _ in
    SwiftLogNoOpLogHandler()
  }

  nonisolated let receiving = AsyncGate()
  nonisolated let cleaningUp = AsyncGate()
  nonisolated let release = AsyncGate()
  private let receiverCancelled = AsyncGate()
  private let inner = SilentTransport()
  private(set) var receiverCancelledOnDisconnect = false

  func connect() async throws {
    try await inner.connect()
  }

  func disconnect() async {
    if !cleaningUp.isOpen {
      receiverCancelledOnDisconnect = receiverCancelled.isOpen
    }
    cleaningUp.open()
    await release.waitIgnoringCancellation()
    await inner.disconnect()
  }

  func send(_ data: Data) async throws {
    try await inner.send(data)
  }

  func receive() -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream(unfolding: { [receiving, release, receiverCancelled] in
      await withTaskCancellationHandler {
        receiving.open()
        await release.waitIgnoringCancellation()
      } onCancel: {
        receiverCancelled.open()
      }
      return nil
    })
  }
}

private actor GatedHandshakeTransport: Transport {
  nonisolated let logger = Logger(label: "test.silent") { _ in
    SwiftLogNoOpLogHandler()
  }

  nonisolated let entered = AsyncGate()
  nonisolated let cancelled = AsyncGate()
  nonisolated let release = AsyncGate()
  nonisolated let finished = AsyncGate()
  private let inner: InMemoryTransport
  private var stream: AsyncThrowingStream<Data, any Error>?

  init(wrapping inner: InMemoryTransport) {
    self.inner = inner
  }

  func connect() async throws {
    defer { finished.open() }
    entered.open()
    await withTaskCancellationHandler(
      operation: {
        await release.waitIgnoringCancellation()
      },
      onCancel: {
        self.cancelled.open()
      }
    )
    try Task.checkCancellation()
    try await inner.connect()
    stream = await inner.receive()
  }

  func disconnect() async {
    await inner.disconnect()
  }

  func send(_ data: Data) async throws {
    try await inner.send(data)
  }

  func receive() -> AsyncThrowingStream<Data, any Error> {
    stream
      ?? AsyncThrowingStream { continuation in
        continuation.finish()
      }
  }
}
