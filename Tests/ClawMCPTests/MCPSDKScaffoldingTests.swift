import MCP
import Testing

@testable import ClawMCP

/// Temporary scaffolding: proves the MCP SDK links and completes a real handshake on our
/// toolchain. Deleted once the session and catalog suites exercise the same path for real.
@Suite("MCP SDK scaffolding")
struct MCPSDKScaffoldingTests {
  @Test("client and server complete the initialize handshake over an in-memory pair")
  func initializeHandshake() async throws {
    // given
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let server = Server(name: "scaffold-server", version: "1.2.3")
    try await server.start(transport: serverTransport)
    let client = Client(name: "swift-claw", version: "0.0.0-dev")

    // when
    let result = try await client.connect(transport: clientTransport)

    // then
    #expect(result.serverInfo.name == "scaffold-server")
    #expect(result.serverInfo.version == "1.2.3")
    #expect(Version.supported.contains(result.protocolVersion))
    #expect(MCPProtocol.version == Version.latest)

    await client.disconnect()
    await server.stop()
  }
}
