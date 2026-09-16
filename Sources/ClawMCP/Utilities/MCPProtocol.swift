import MCP

/// Wire-protocol coordinates swift-claw pins when talking to MCP servers.
public enum MCPProtocol {
  /// Value sent in the `MCP-Protocol-Version` header on every Streamable HTTP
  /// request, and offered in the initialize handshake.
  ///
  /// Tracks the newest revision the linked SDK can speak; servers that only
  /// support an older revision negotiate down during initialize.
  public static let version: String = Version.latest

  /// What we call ourselves in the initialize handshake. The version alongside it is the daemon's
  /// build, threaded in from composition, so a server's logs name a real build.
  public static let clientName = "swift-claw"
}
