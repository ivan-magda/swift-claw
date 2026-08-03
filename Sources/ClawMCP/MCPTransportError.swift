import ClawCore

/// A Streamable HTTP exchange that did not deliver a JSON-RPC message.
///
/// Every case is safe to render: nothing here quotes the server's body, so a failure can be logged
/// or shown to the owner without carrying remote text into a place that reads as our own words.
public enum MCPTransportError: Error, Sendable, Equatable {
  /// A send arrived before `connect()`, or after `disconnect()` spent the instance.
  case notConnected
  /// The server no longer knows the session id we replayed; a fresh transport must re-initialize.
  case sessionExpired
  case httpStatus(Int)
  /// A 2xx whose body is neither JSON nor an event stream, so it holds no message we can parse.
  case unsupportedContentType(String)
  case oversizedMessage(limitBytes: Int)
  /// The HTTP seam's own failure — a timeout, a refused connection, a broken stream — kept whole so
  /// callers can read the disposition it already decided.
  case requestFailed(HTTPTransportFailure)

  /// Whether the attempt could have reached the server. A remote call that may have run is not the
  /// same as one that provably did not, and only the failure knows which it was.
  public var disposition: HTTPTransmissionDisposition {
    switch self {
    case .notConnected:
      return .definitelyNotSent
    case .sessionExpired, .httpStatus, .unsupportedContentType, .oversizedMessage:
      return .mayHaveBeenSent
    case .requestFailed(let failure):
      return failure.disposition
    }
  }
}

extension MCPTransportError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .notConnected:
      return "MCP transport is not connected"
    case .sessionExpired:
      return "MCP session expired"
    case .httpStatus(let code):
      return "MCP server returned HTTP \(code)"
    case .unsupportedContentType(let value):
      return "MCP server returned an unsupported content type: \(value)"
    case .oversizedMessage(let limitBytes):
      return "MCP message exceeds the \(limitBytes)-byte limit"
    case .requestFailed(let failure):
      return "MCP request failed: \(failure.safeMessage)"
    }
  }
}
