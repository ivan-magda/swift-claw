import ClawCore
import ClawTestSupport
import Foundation
import Logging
import Testing

@testable import ClawMCP

@Suite("MCP transport exchange ownership")
struct MCPTransportLifecycleTests {
  @Test(
    "disconnect joins an admitted exchange and returns even a late-created session",
    arguments: [DisconnectPhase.opening, .body]
  )
  func disconnectJoinsExchange(phase: DisconnectPhase) async throws {
    // given
    let http = DisconnectRaceHTTP()
    defer {
      http.releaseHead.open()
      http.releaseBody.open()
    }
    let transport = try Self.transport(http: http)
    try await transport.connect()
    let sending = Task {
      try await transport.send(Data())
    }
    #expect(await http.opening.waitUntilOpen())
    var receiving: Task<Void, Never>?
    if phase == .body {
      let received = AsyncGate()
      let messages = await transport.receive()
      receiving = Task {
        var iterator = messages.makeAsyncIterator()
        let reply = try? await iterator.next()
        #expect(reply == Data(DisconnectRaceHTTP.reply.utf8))
        received.open()
      }
      http.releaseHead.open()
      #expect(await received.waitUntilOpen())
    }

    // when
    let disconnecting = Task {
      await transport.disconnect()
      #expect(http.bodyStopped.isOpen)
      #expect(http.deleteFinished.isOpen)
    }
    if phase == .opening {
      #expect(await http.headCancelled.waitUntilOpen())
      http.releaseHead.open()
    }
    #expect(await http.bodyCancelled.waitUntilOpen())
    http.releaseBody.open()
    await disconnecting.value
    _ = await sending.result
    await receiving?.value

    // then
    let requests = await http.teardown.recorded
    #expect(requests.count == 1)
    let deletion = try #require(requests.first)
    #expect(deletion.method == .delete)
    #expect(deletion.headers[MCPHTTPHeader.session] == DisconnectRaceHTTP.sessionID)
  }

  @Test("cancelling a send cancels its HTTP request without disconnecting")
  func callerCancellationStopsExchange() async throws {
    // given
    let http = DisconnectRaceHTTP()
    defer {
      http.releaseHead.open()
      http.releaseBody.open()
    }
    let transport = try Self.transport(http: http)
    try await transport.connect()
    let sending = Task {
      try await transport.send(Data())
    }
    #expect(await http.opening.waitUntilOpen())

    // when
    sending.cancel()

    // then
    #expect(await http.headCancelled.waitUntilOpen())
    http.releaseHead.open()
    http.releaseBody.open()
    let result = await sending.result
    #expect(throws: CancellationError.self) {
      try result.get()
    }
    await transport.disconnect()
  }

  @Test("concurrent disconnects both await the same session deletion")
  func concurrentDisconnectsJoinDeletion() async throws {
    // given
    let deleteStarted = AsyncGate()
    let releaseDelete = AsyncGate()
    let deleteFinished = AsyncGate()
    defer {
      releaseDelete.open()
    }
    let http = ScriptedHTTPExecutor([
      .stream(
        HTTPStreamHead(
          statusCode: 202,
          headers: [MCPHTTPHeader.session: "shared-session"]
        ),
        []
      ),
      .responding { _ in
        deleteStarted.open()
        await releaseDelete.waitIgnoringCancellation()
        deleteFinished.open()
        return HTTPResult(statusCode: 204, headers: [:], body: Data())
      },
    ])
    let transport = try Self.transport(http: http)
    try await transport.connect()
    try await transport.send(Data())
    let disconnecting = Task {
      await transport.disconnect()
      #expect(deleteFinished.isOpen)
    }
    let deleting = await deleteStarted.waitUntilOpen()
    #expect(deleting)

    // when
    if deleting {
      let joined = await Self.joinHeldDisconnect(
        transport,
        releaseDelete: releaseDelete,
        deleteFinished: deleteFinished
      )
      #expect(joined)
    } else {
      releaseDelete.open()
    }
    await disconnecting.value

    // then
    let deletions = await http.recorded.filter {
      $0.method == .delete
    }
    #expect(deletions.count == 1)
  }
}

// MARK: - Test setup

private extension MCPTransportLifecycleTests {
  static func transport(
    http: any HTTPExecuting & HTTPStreaming
  ) throws -> MCPStreamableHTTPTransport {
    let config = try MCPServerConfig(name: "test", url: "https://mcp.example.com/mcp")
    let logger = Logger(label: "test.silent") { _ in
      SwiftLogNoOpLogHandler()
    }
    return MCPStreamableHTTPTransport(server: config, http: http, logger: logger)
  }

  static func joinHeldDisconnect(
    _ transport: isolated MCPStreamableHTTPTransport,
    releaseDelete: AsyncGate,
    deleteFinished: AsyncGate
  ) async -> Bool {
    // Enter the second disconnect on the transport actor before allowing DELETE to finish.
    let joining = Task.immediate {
      await transport.disconnect()
      return deleteFinished.isOpen
    }
    releaseDelete.open()
    return await joining.value
  }
}

// MARK: - Gated HTTP exchange

extension MCPTransportLifecycleTests {
  enum DisconnectPhase: Sendable {
    case opening
    case body
  }
}

private struct DisconnectRaceHTTP: HTTPExecuting, HTTPStreaming {
  static let sessionID = "late-session"
  static let reply = #"{"jsonrpc":"2.0","id":1,"result":{}}"#

  let opening = AsyncGate()
  let headCancelled = AsyncGate()
  let releaseHead = AsyncGate()
  let bodyCancelled = AsyncGate()
  let releaseBody = AsyncGate()
  let bodyStopped = AsyncGate()
  let deleteFinished = AsyncGate()
  let teardown: ScriptedHTTPExecutor

  init() {
    let bodyStopped = bodyStopped
    let deleteFinished = deleteFinished
    teardown = ScriptedHTTPExecutor([
      .responding { _ in
        #expect(bodyStopped.isOpen)
        deleteFinished.open()
        return HTTPResult(statusCode: 204, headers: [:], body: Data())
      },
    ])
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    try await teardown.execute(request)
  }

  func openStream(_ request: HTTPRequest) async throws -> HTTPStreamExchange {
    opening.open()
    await withTaskCancellationHandler {
      await releaseHead.waitIgnoringCancellation()
    } onCancel: {
      headCancelled.open()
    }
    return HTTPStreamExchange.make(
      head: HTTPStreamHead(
        statusCode: 200,
        headers: [
          MCPHTTPHeader.contentType: "text/event-stream",
          MCPHTTPHeader.session: Self.sessionID,
        ]
      ),
      maximumUnreadBodyBytes: MCPTransportLimits.maxMessageBytes
    ) { sink in
      await withTaskCancellationHandler {
        try? await sink.send(Data("data: \(Self.reply)\n\n".utf8))
        await releaseBody.waitIgnoringCancellation()
      } onCancel: {
        bodyCancelled.open()
      }
      bodyStopped.open()
      return Task.isCancelled ? .cancelled(.mayHaveBeenSent) : .completed
    }
  }
}
