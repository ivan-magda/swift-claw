/// A session-level failure: the server answered, but not with something usable.
///
/// Like `MCPTransportError`, every case is safe to render — none quotes the server's body — so a
/// doctor row or a skip reason built from one carries our words, not a third party's.
public enum MCPSessionError: Error, Sendable, Equatable {
  /// The call outlived the whole budget a tool call is allowed (connect plus request).
  case callTimedOut(seconds: Int)
  /// A handshake or tool-list exchange outlived that same budget. The HTTP timeouts bound each
  /// exchange, but a server that answers one without ever sending the response our request is
  /// waiting for leaves nothing for them to fire on.
  case discoveryTimedOut(seconds: Int)
  case tooManyPages(limit: Int)
  case tooManyTools(limit: Int)
  case catalogTooLarge(limitBytes: Int)
  /// The server handed back a cursor it had already given us, so paging would never end.
  case pagingStalled
}

extension MCPSessionError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .callTimedOut(let seconds):
      return "MCP call exceeded its \(seconds)s budget"
    case .discoveryTimedOut(let seconds):
      return "MCP server did not finish discovery within its \(seconds)s budget"
    case .tooManyPages(let limit):
      return "MCP server paginated its tool list past \(limit) pages"
    case .tooManyTools(let limit):
      return "MCP server offers more than \(limit) tools"
    case .catalogTooLarge(let limitBytes):
      return "MCP tool list exceeds the \(limitBytes)-byte limit"
    case .pagingStalled:
      return "MCP server repeated a pagination cursor"
    }
  }
}
