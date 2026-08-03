import ClawCore
import Foundation

/// A Streamable HTTP exchange that did not deliver a JSON-RPC message.
///
/// Every case is safe to render. Nothing quotes the server's body, and the one case that carries a
/// server-supplied string renders it only through `mediaTypeDescription`, so a failure can be logged
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
  case receiveBufferOverflow(limitMessages: Int)
  /// The HTTP exchange completed, but its reply could not enter the already-closed receive stream.
  case receiveStreamTerminated
  /// The HTTP seam's own failure — a timeout, a refused connection, a broken stream — kept whole so
  /// callers can read the disposition it already decided.
  case requestFailed(HTTPTransportFailure)

  /// Whether the attempt could have reached the server. A remote call that may have run is not the
  /// same as one that provably did not, and only the failure knows which it was.
  public var disposition: HTTPTransmissionDisposition {
    switch self {
    case .notConnected:
      return .definitelyNotSent
    case .sessionExpired, .httpStatus, .unsupportedContentType, .oversizedMessage,
      .receiveBufferOverflow, .receiveStreamTerminated:
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
      return "MCP server returned an unsupported content type: \(Self.mediaTypeDescription(value))"
    case .oversizedMessage(let limitBytes):
      return "MCP message exceeds the \(limitBytes)-byte limit"
    case .receiveBufferOverflow(let limitMessages):
      return "MCP receive buffer exceeds the \(limitMessages)-message limit"
    case .receiveStreamTerminated:
      return "MCP receive stream ended before the response could be delivered"
    case .requestFailed(let failure):
      return "MCP request failed: \(failure.safeMessage)"
    }
  }

  /// A `Content-Type` header is written by the server, and this failure is rendered as our own
  /// words — into a payload the trifecta gate treats as trusted. So the header is echoed back only
  /// when it is shaped like a media type; anything else is named rather than quoted, and a server
  /// gets no channel for arbitrary text through a diagnostic.
  private static func mediaTypeDescription(_ raw: String) -> String {
    let mediaType = raw.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
    let parts = mediaType.split(separator: "/", omittingEmptySubsequences: false)
    let wellFormed =
      parts.count == 2 && mediaType.count <= 64
      && parts.allSatisfy { $0.isEmpty == false && $0.allSatisfy(isMediaTypeCharacter) }

    return wellFormed ? mediaType : "unrecognized"
  }

  /// RFC 9110 token characters, minus the ones no registered media type uses. Narrow on purpose:
  /// the point is a shape we can vouch for, not fidelity to every legal header.
  private static func isMediaTypeCharacter(_ character: Character) -> Bool {
    character.isLetter && character.isASCII || character.isNumber && character.isASCII
      || "+-._".contains(character)
  }
}
