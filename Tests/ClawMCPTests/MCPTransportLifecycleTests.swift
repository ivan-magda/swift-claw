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
    let config = try MCPServerConfig(name: "test", url: "https://mcp.example.com/mcp")
    let logger = Logger(label: "test.silent") { _ in
      SwiftLogNoOpLogHandler()
    }
    let transport = MCPStreamableHTTPTransport(server: config, http: http, logger: logger)
    try await transport.connect()
    let sending = Task {
      try await transport.send(Data())
    }
    #expect(await http.opening.waitUntilOpen())
    if phase == .body {
      http.releaseHead.open()
      #expect(await http.bodyStarted.waitUntilOpen())
    }

    // when
    let disconnecting = Task {
      await transport.disconnect()
    }
    if phase == .opening {
      #expect(await http.headCancelled.waitUntilOpen())
      http.releaseHead.open()
    }
    #expect(await http.bodyCancelled.waitUntilOpen())
    http.releaseBody.open()
    await disconnecting.value
    _ = await sending.result

    // then
    let requests = await http.teardown.recorded
    #expect(requests.count == 1)
    let deletion = try #require(requests.first)
    #expect(deletion.method == .delete)
    #expect(deletion.headers[MCPHTTPHeader.session] == DisconnectRaceHTTP.sessionID)
    #expect(http.bodyStopped.isOpen)
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

  let opening = AsyncGate()
  let headCancelled = AsyncGate()
  let releaseHead = AsyncGate()
  let bodyStarted = AsyncGate()
  let bodyCancelled = AsyncGate()
  let releaseBody = AsyncGate()
  let bodyStopped = AsyncGate()
  let teardown: ScriptedHTTPExecutor

  init() {
    let bodyStopped = bodyStopped
    teardown = ScriptedHTTPExecutor([
      .responding { _ in
        #expect(bodyStopped.isOpen)
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
          MCPHTTPHeader.contentType: "application/json",
          MCPHTTPHeader.session: Self.sessionID,
        ]
      ),
      maximumUnreadBodyBytes: MCPTransportLimits.maxMessageBytes
    ) { _ in
      bodyStarted.open()
      await withTaskCancellationHandler {
        await releaseBody.waitIgnoringCancellation()
      } onCancel: {
        bodyCancelled.open()
      }
      bodyStopped.open()
      return Task.isCancelled ? .cancelled(.mayHaveBeenSent) : .completed
    }
  }
}
