import ClawCore
import ClawMCP
import Foundation

/// A minimal MCP server answering JSON-RPC over swift-claw's HTTP seam.
///
/// The composition path runs the real Streamable HTTP transport against a real SDK `Client`, and the
/// SDK stamps every request with a fresh UUID — a canned response queue could never be matched to
/// one, which is why this reads each request and answers it by id. That is what lets the whole boot
/// chain (transport → session → resolver → adapter) be driven with no socket anywhere in it.
actor ScriptedMCPHTTPServer: HTTPExecuting, HTTPStreaming {
  /// One tool the server advertises. The schema stays raw JSON text so this type is `Sendable` and
  /// the normalizer sees exactly the bytes a real server would send.
  struct RemoteTool: Sendable {
    static let defaultSchemaJSON =
      #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#

    let name: String
    let description: String
    let schemaJSON: String

    init(
      name: String,
      description: String = "a remote tool",
      schemaJSON: String = defaultSchemaJSON
    ) {
      self.name = name
      self.description = description
      self.schemaJSON = schemaJSON
    }
  }

  /// What `tools/call` answers with — either a result or the server's own report that it failed.
  enum CallOutcome: Sendable {
    case text(String)
    case reportedFailure(String)
  }

  static let sessionID = "scripted-mcp-session"

  private let tools: [RemoteTool]
  private let outcome: CallOutcome
  private(set) var calledTools: [String] = []
  /// What each request authenticated with — the seam a token-binding assertion reads, since the
  /// token itself must never reach a report or a log line.
  private(set) var authorizationHeaders: [String] = []

  init(tools: [RemoteTool], outcome: CallOutcome = .text("the remote tool answered")) {
    self.tools = tools
    self.outcome = outcome
  }

  /// The session-teardown DELETE is the only buffered request this server ever receives.
  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    HTTPResult(statusCode: 200, headers: [:], body: Data())
  }

  func openStream(_ request: HTTPRequest) async throws -> HTTPStreamExchange {
    guard case .streaming(let maximumUnreadBytes, _) = request.responseBodyPolicy else {
      throw HTTPTransportFailure.policyMismatch(
        HTTPResponseBodyPolicy.streamingPolicyRequiredMessage
      )
    }

    if let authorization = request.headers["Authorization"] {
      authorizationHeaders.append(authorization)
    }

    let reply = try answer(to: request.body ?? Data())
    let head = HTTPStreamHead(
      statusCode: reply.status,
      headers: [
        "Content-Type": "application/json",
        "Mcp-Session-Id": Self.sessionID,
      ]
    )

    return HTTPStreamExchange.make(head: head, maximumUnreadBodyBytes: maximumUnreadBytes) { sink in
      guard reply.body.isEmpty == false else {
        return .completed
      }
      do {
        try await sink.send(reply.body)
      } catch {
        return .cancelled(.mayHaveBeenSent)
      }
      return .completed
    }
  }
}

// MARK: - JSON-RPC

private extension ScriptedMCPHTTPServer {
  func answer(to body: Data) throws -> (status: Int, body: Data) {
    guard
      let message = try JSONSerialization.jsonObject(with: body) as? [String: Any],
      let method = message["method"] as? String
    else {
      return (400, Data())
    }
    // No id means a notification: 202 and nothing to answer, exactly as the spec has it.
    guard let id = message["id"] else {
      return (202, Data())
    }

    switch method {
    case "initialize":
      return (200, try response(id: id, result: initializeResult()))
    case "tools/list":
      return (200, try response(id: id, result: try listResult()))
    case "tools/call":
      let parameters = message["params"] as? [String: Any] ?? [:]
      calledTools.append(parameters["name"] as? String ?? "")
      return (200, try response(id: id, result: callResult()))
    default:
      return (200, try response(id: id, result: [:]))
    }
  }

  func response(id: Any, result: [String: Any]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]
    )
  }

  func initializeResult() -> [String: Any] {
    [
      "protocolVersion": MCPProtocol.version,
      "capabilities": ["tools": ["listChanged": false]],
      "serverInfo": ["name": "scripted", "version": "1.0.0"],
    ]
  }

  func listResult() throws -> [String: Any] {
    [
      "tools": try tools.map { tool in
        [
          "name": tool.name,
          "description": tool.description,
          "inputSchema": try JSONSerialization.jsonObject(with: Data(tool.schemaJSON.utf8)),
        ]
      }
    ]
  }

  func callResult() -> [String: Any] {
    switch outcome {
    case .text(let text):
      return ["content": [["type": "text", "text": text]], "isError": false]
    case .reportedFailure(let text):
      return ["content": [["type": "text", "text": text]], "isError": true]
    }
  }
}
