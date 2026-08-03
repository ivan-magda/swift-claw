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

/// Which remote tools a server contributes, and the tier they land on.
public struct MCPToolFilter: Sendable, Equatable {
  /// Remote (unprefixed) names. When non-empty this is the whole allowed set and `exclude` is
  /// ignored — an owner who names both meant the narrower one.
  public let include: [String]
  public let exclude: [String]
  /// Owner downgrades, keyed by remote name. Absent means `.ask`; `.dangerous` is rejected at load.
  public let risk: [String: RiskLevel]

  public static let allowAll = MCPToolFilter()

  public init(
    include: [String] = [],
    exclude: [String] = [],
    risk: [String: RiskLevel] = [:]
  ) {
    self.include = include
    self.exclude = exclude
    self.risk = risk
  }

  public func allows(_ remoteName: String) -> Bool {
    guard include.isEmpty else {
      return include.contains(remoteName)
    }
    return exclude.contains(remoteName) == false
  }

  /// The tier a remote tool lands on. Every MCP tool is `.ask` unless the owner downgraded it.
  public func riskLevel(for remoteName: String) -> RiskLevel {
    risk[remoteName] ?? .ask
  }
}

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

    let trimmedAuthHeader = authHeader.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedAuthHeader.isEmpty == false else {
      throw MCPConfigError.invalidValue(key: "authHeader", value: authHeader)
    }
    // A static header of the same name would silently shadow the stored token, which is exactly the
    // shape of an owner pasting a plaintext credential into the file we told them not to.
    guard
      headers.keys.contains(where: { $0.caseInsensitiveCompare(trimmedAuthHeader) == .orderedSame })
        == false
    else {
      throw MCPConfigError.invalidValue(key: "headers", value: trimmedAuthHeader)
    }

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
