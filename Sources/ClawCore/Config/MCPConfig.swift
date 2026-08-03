import Foundation

/// Pinned sizing for the MCP client. A personal daemon talks to a handful of servers, so these are
/// deliberately small; an implementer changing one changes it here and in the plan's constant table.
public enum MCPLimits {
  public static let defaultAuthHeader = "Authorization"
  public static let defaultConnectTimeoutSeconds = 10
  public static let defaultRequestTimeoutSeconds = 30

  public static let connectTimeoutRange = 1...120
  public static let requestTimeoutRange = 1...600

  /// File probed under the state root when `CLAW_MCP_CONFIG` is unset.
  public static let configFileName = "mcp.yaml"
}

/// Header names owned by MCP or the HTTP transport, plus the RFC field-shape checks shared by config
/// validation and the transport.
public enum MCPHTTPHeader {
  public static let accept = "Accept"
  public static let contentType = "Content-Type"
  public static let protocolVersion = "MCP-Protocol-Version"
  public static let session = "Mcp-Session-Id"

  private static let reserved = Set(
    [
      accept,
      contentType,
      protocolVersion,
      session,
      "Connection",
      "Content-Length",
      "Host",
      "Keep-Alive",
      "Proxy-Connection",
      "TE",
      "Trailer",
      "Transfer-Encoding",
      "Upgrade",
    ].map { name in name.lowercased() }
  )

  public static func isReserved(_ name: String) -> Bool {
    reserved.contains(name.lowercased())
  }

  /// RFC 9110 `field-name` is an ASCII token. Validating before NIO sees it turns malformed owner
  /// config into a typed startup error instead of an `HTTPHeaders` precondition failure.
  public static func isValidName(_ name: String) -> Bool {
    name.isEmpty == false && name.utf8.allSatisfy(isTokenByte)
  }

  /// Field values may carry printable Unicode, but never controls that can create another line or
  /// another field on the wire. Horizontal tab is the one HTTP whitespace control RFC 9110 permits.
  public static func isValidValue(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
      let codePoint = scalar.value
      if codePoint == 0x09 {
        return true
      }
      return codePoint >= 0x20 && codePoint != 0x7F && (0x80...0x9F).contains(codePoint) == false
    }
  }

  private static func isTokenByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
      UInt8(ascii: "0")...UInt8(ascii: "9"):
      return true
    default:
      return "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
  }
}

/// Where the server catalog is read from, and whether the owner named it.
///
/// The distinction is the failure policy: a path the owner typed must exist (a typo is an owner
/// error, loud), while the probed default is simply how the feature stays off by default.
public enum MCPConfigSource: Sendable, Equatable {
  case explicit(URL)
  case probed(URL)

  public var url: URL {
    switch self {
    case .explicit(let url), .probed(let url):
      return url
    }
  }

  public var isExplicit: Bool {
    if case .explicit = self {
      return true
    }
    return false
  }
}

// An empty allowlist and no allowlist have different meanings in the owner config.
// swiftlint:disable discouraged_optional_collection
/// Which remote tools a server contributes, and the tier they land on.
public struct MCPToolFilter: Sendable, Equatable {
  /// Remote (unprefixed) names. Presence makes this the whole allowed set and ignores `exclude`;
  /// an explicitly empty list therefore exposes no tools, while nil means no allowlist was set.
  public let include: [String]?
  public let exclude: [String]
  /// Owner downgrades, keyed by remote name. Absent means `.ask`; `.dangerous` is rejected at load.
  public let risk: [String: RiskLevel]

  public static let allowAll = MCPToolFilter()

  public init(
    include: [String]? = nil,
    exclude: [String] = [],
    risk: [String: RiskLevel] = [:]
  ) {
    self.include = include
    self.exclude = exclude
    self.risk = risk
  }

  public func allows(_ remoteName: String) -> Bool {
    guard let include else {
      return exclude.contains(remoteName) == false
    }
    return include.contains(remoteName)
  }

  /// The tier a remote tool lands on. Every MCP tool is `.ask` unless the owner downgraded it.
  public func riskLevel(for remoteName: String) -> RiskLevel {
    risk[remoteName] ?? .ask
  }
}
// swiftlint:enable discouraged_optional_collection

/// One owner-configured MCP server. Construction validates, so a value of this type is always
/// dispatchable: reachable-shaped URL, usable header names, timeouts inside their bounds, and no
/// tier the gate would refuse to honor.
public struct MCPServerConfig: Sendable, Equatable {
  public let name: String
  public let url: URL
  public let enabled: Bool
  /// Non-secret extras sent on every request. Tokens live in the encrypted credential store.
  public let headers: [String: String]
  public let authHeader: String
  public let connectTimeoutSeconds: Int
  public let requestTimeoutSeconds: Int
  public let tools: MCPToolFilter

  public init(
    name: String,
    url rawURL: String,
    enabled: Bool = true,
    headers: [String: String] = [:],
    authHeader: String = MCPLimits.defaultAuthHeader,
    connectTimeoutSeconds: Int = MCPLimits.defaultConnectTimeoutSeconds,
    requestTimeoutSeconds: Int = MCPLimits.defaultRequestTimeoutSeconds,
    tools: MCPToolFilter = .allowAll
  ) throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedName.isEmpty == false,
      MCPNaming.sanitizeFragment(trimmedName).isEmpty == false
    else {
      throw MCPConfigError.invalidServerName(name)
    }

    let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedURL), let scheme = url.scheme?.lowercased() else {
      throw MCPConfigError.invalidURL(server: trimmedName, value: rawURL)
    }
    // Scheme before host: a `file:` URL has no host either, and naming the scheme is the answer the
    // owner needs.
    guard scheme == "http" || scheme == "https" else {
      throw MCPConfigError.unsupportedScheme(server: trimmedName, value: scheme)
    }
    guard url.host?.isEmpty == false else {
      throw MCPConfigError.invalidURL(server: trimmedName, value: rawURL)
    }

    let trimmedAuthHeader = try Self.validateHeaders(headers, authHeader: authHeader)

    guard MCPLimits.connectTimeoutRange.contains(connectTimeoutSeconds) else {
      throw MCPConfigError.invalidValue(
        key: "connectTimeoutSeconds",
        value: "\(connectTimeoutSeconds)"
      )
    }
    guard MCPLimits.requestTimeoutRange.contains(requestTimeoutSeconds) else {
      throw MCPConfigError.invalidValue(
        key: "requestTimeoutSeconds",
        value: "\(requestTimeoutSeconds)"
      )
    }

    for (toolName, level) in tools.risk where level == .dangerous {
      throw MCPConfigError.dangerousRiskOverride(server: trimmedName, tool: toolName)
    }

    self.name = trimmedName
    self.url = url
    self.enabled = enabled
    self.headers = headers
    self.authHeader = trimmedAuthHeader
    self.connectTimeoutSeconds = connectTimeoutSeconds
    self.requestTimeoutSeconds = requestTimeoutSeconds
    self.tools = tools
  }

  /// Worst case for one tool call: a dead session reconnects, then the call runs.
  public var worstCaseCallSeconds: Int {
    connectTimeoutSeconds + requestTimeoutSeconds
  }

  /// What `authHeader` carries for `token`. `Bearer` is the `Authorization` header's scheme, not a
  /// property of the token, so a server configured onto a header of its own (an API-key header, say)
  /// receives the token exactly as the owner set it.
  public func authorizationValue(for token: String) -> String {
    guard authHeader.caseInsensitiveCompare(MCPLimits.defaultAuthHeader) == .orderedSame else {
      return token
    }
    return "Bearer \(token)"
  }
}

// MARK: - Header Validation

private extension MCPServerConfig {
  static func validateHeaders(
    _ headers: [String: String],
    authHeader: String
  ) throws -> String {
    let trimmedAuthHeader = authHeader.trimmingCharacters(in: .whitespacesAndNewlines)
    guard MCPHTTPHeader.isValidName(trimmedAuthHeader) else {
      throw MCPConfigError.invalidValue(key: "authHeader", value: "invalid HTTP field name")
    }
    guard MCPHTTPHeader.isReserved(trimmedAuthHeader) == false else {
      throw MCPConfigError.invalidValue(key: "authHeader", value: "reserved transport header")
    }
    var seenHeaderNames: Set<String> = []
    for (header, value) in headers {
      guard MCPHTTPHeader.isValidName(header) else {
        throw MCPConfigError.invalidValue(key: "headers", value: "invalid HTTP field name")
      }
      guard MCPHTTPHeader.isReserved(header) == false else {
        throw MCPConfigError.invalidValue(key: "headers", value: "reserved transport header")
      }
      guard seenHeaderNames.insert(header.lowercased()).inserted else {
        throw MCPConfigError.invalidValue(key: "headers", value: "duplicate HTTP field name")
      }
      guard MCPHTTPHeader.isValidValue(value) else {
        throw MCPConfigError.invalidValue(key: "headers", value: "invalid HTTP field value")
      }
    }

    // A static header of the same name would shadow the stored token.
    let shadowsToken = headers.keys.contains { header in
      header.caseInsensitiveCompare(trimmedAuthHeader) == .orderedSame
    }
    guard shadowsToken == false else {
      throw MCPConfigError.invalidValue(key: "headers", value: trimmedAuthHeader)
    }
    return trimmedAuthHeader
  }
}

/// The owner's whole MCP catalog. Empty means the feature is off.
public struct MCPConfig: Sendable, Equatable {
  public let servers: [MCPServerConfig]

  public static let empty = MCPConfig(unchecked: [])

  private init(unchecked servers: [MCPServerConfig]) {
    self.servers = servers
  }

  /// Rejects names that collide once sanitized: two servers folding to the same tool-name prefix
  /// would make `mcp__<server>__<tool>` ambiguous, and renaming behind the owner's back is worse
  /// than refusing to boot.
  public init(servers: [MCPServerConfig]) throws {
    var seen: Set<String> = []
    for server in servers {
      let sanitized = MCPNaming.sanitizeFragment(server.name)
      guard seen.insert(sanitized).inserted else {
        throw MCPConfigError.duplicateServerName(sanitized)
      }
    }
    self.init(unchecked: servers)
  }

  public var enabledServers: [MCPServerConfig] {
    servers.filter(\.enabled)
  }
}
