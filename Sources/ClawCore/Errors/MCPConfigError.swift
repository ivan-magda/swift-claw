/// A rejected `mcp.yaml`. Distinct from `ConfigError`, which speaks the env-var vocabulary: these
/// name a file, a key path inside it, or a server the owner wrote.
public enum MCPConfigError: Error, Sendable, Equatable {
  /// The file named by `CLAW_MCP_CONFIG` is missing, or a present file could not be read as UTF-8.
  case unreadableFile(path: String)
  case malformed(reason: String)
  /// A key path we do not know — a typo an owner would otherwise debug as "my setting is ignored".
  case unknownKey(String)
  case missingValue(key: String)
  case invalidValue(key: String, value: String)
  case invalidServerName(String)
  case invalidURL(server: String, value: String)
  case unsupportedScheme(server: String, value: String)
  /// Two server names that fold to the same sanitized tool-name prefix.
  case duplicateServerName(String)
  case dangerousRiskOverride(server: String, tool: String)

  /// Every case is the owner's file being wrong, so one exit code covers them all.
  public var exitCode: Int32 { ClawExitCode.configInvalid.rawValue }
}

extension MCPConfigError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .unreadableFile(let path):
      return "cannot read MCP config at \(path)"
    case .malformed(let reason):
      return "malformed MCP config: \(reason)"
    case .unknownKey(let key):
      return "unknown key '\(key)' in MCP config"
    case .missingValue(let key):
      return "missing required key '\(key)' in MCP config"
    case .invalidValue(let key, let value):
      return "invalid value for '\(key)' in MCP config: \(value)"
    case .invalidServerName(let name):
      return "invalid MCP server name: '\(name)'"
    case .invalidURL(let server, let value):
      return "invalid url for MCP server '\(server)': \(value)"
    case .unsupportedScheme(let server, let value):
      return "unsupported scheme '\(value)' for MCP server '\(server)' (http or https only)"
    case .duplicateServerName(let name):
      return "duplicate MCP server name after sanitization: '\(name)'"
    case .dangerousRiskOverride(let server, let tool):
      return "MCP server '\(server)' cannot mark tool '\(tool)' dangerous"
    }
  }
}
