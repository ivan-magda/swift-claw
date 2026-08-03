import ClawCore
import Foundation
import Yams

/// Decodes `mcp.yaml` into the validated `MCPConfig` domain type.
///
/// The mapping is walked by hand rather than through `Codable` because a synthesized decoder
/// silently drops keys it does not know, and a silently ignored server setting is the failure an
/// owner debugs longest.
public enum MCPConfigLoader {
  private enum TopLevelKey {
    static let servers = "servers"
    static let all: Set<String> = [servers]
  }

  private enum ServerKey {
    static let name = "name"
    static let url = "url"
    static let enabled = "enabled"
    static let headers = "headers"
    static let authHeader = "authHeader"
    static let connectTimeoutSeconds = "connectTimeoutSeconds"
    static let requestTimeoutSeconds = "requestTimeoutSeconds"
    static let tools = "tools"
    static let all: Set<String> = [
      name, url, enabled, headers, authHeader, connectTimeoutSeconds, requestTimeoutSeconds, tools,
    ]
  }

  private enum ToolsKey {
    static let include = "include"
    static let exclude = "exclude"
    static let risk = "risk"
    static let all: Set<String> = [include, exclude, risk]
  }

  /// Reads and decodes the catalog. An absent probed file means the feature is off; an absent file
  /// the owner named by env var is their error.
  public static func load(
    from source: MCPConfigSource,
    fileManager: FileManager = .default
  ) throws -> MCPConfig {
    let path = source.url.path

    guard fileManager.fileExists(atPath: path) else {
      guard source.isExplicit else {
        return .empty
      }
      throw MCPConfigError.unreadableFile(path: path)
    }

    guard
      let data = fileManager.contents(atPath: path),
      let text = String(data: data, encoding: .utf8)
    else {
      throw MCPConfigError.unreadableFile(path: path)
    }

    return try parse(yaml: text)
  }

  public static func parse(yaml: String) throws -> MCPConfig {
    let loaded: Any?
    do {
      loaded = try Yams.load(yaml: yaml)
    } catch {
      throw MCPConfigError.malformed(reason: "\(error)")
    }

    guard let loaded else {
      return .empty  // empty or comment-only file
    }
    guard let root = loaded as? [String: Any] else {
      throw MCPConfigError.malformed(reason: "top level must be a mapping")
    }
    try requireKnownKeys(in: root, allowed: TopLevelKey.all, context: nil)

    guard let rawServers = unwrapped(root[TopLevelKey.servers]) else {
      return .empty
    }
    guard let entries = rawServers as? [Any] else {
      throw MCPConfigError.invalidValue(key: TopLevelKey.servers, value: "expected a list")
    }

    let servers = try entries.enumerated().map { index, entry in
      try parseServer(entry, context: "\(TopLevelKey.servers)[\(index)]")
    }
    return try MCPConfig(servers: servers)
  }
}

// MARK: - Server Decoding

private extension MCPConfigLoader {
  static func parseServer(_ entry: Any, context: String) throws -> MCPServerConfig {
    guard let mapping = entry as? [String: Any] else {
      throw MCPConfigError.invalidValue(key: context, value: "expected a mapping")
    }
    try requireKnownKeys(in: mapping, allowed: ServerKey.all, context: context)

    let name = try requiredString(mapping[ServerKey.name], key: "\(context).\(ServerKey.name)")
    let url = try requiredString(mapping[ServerKey.url], key: "\(context).\(ServerKey.url)")

    return try MCPServerConfig(
      name: name,
      url: url,
      enabled: try boolValue(
        mapping[ServerKey.enabled],
        key: "\(context).\(ServerKey.enabled)",
        default: true
      ),
      headers: try optionalStringMap(
        mapping[ServerKey.headers],
        key: "\(context).\(ServerKey.headers)"
      ),
      authHeader: try optionalString(
        mapping[ServerKey.authHeader],
        key: "\(context).\(ServerKey.authHeader)"
      ) ?? MCPLimits.defaultAuthHeader,
      connectTimeoutSeconds: try optionalInt(
        mapping[ServerKey.connectTimeoutSeconds],
        key: "\(context).\(ServerKey.connectTimeoutSeconds)"
      ) ?? MCPLimits.defaultConnectTimeoutSeconds,
      requestTimeoutSeconds: try optionalInt(
        mapping[ServerKey.requestTimeoutSeconds],
        key: "\(context).\(ServerKey.requestTimeoutSeconds)"
      ) ?? MCPLimits.defaultRequestTimeoutSeconds,
      tools: try parseTools(mapping[ServerKey.tools], context: "\(context).\(ServerKey.tools)")
    )
  }

  static func parseTools(_ raw: Any?, context: String) throws -> MCPToolFilter {
    guard let raw = unwrapped(raw) else {
      return .allowAll
    }
    guard let mapping = raw as? [String: Any] else {
      throw MCPConfigError.invalidValue(key: context, value: "expected a mapping")
    }
    try requireKnownKeys(in: mapping, allowed: ToolsKey.all, context: context)

    return MCPToolFilter(
      include: try presentStringList(
        mapping[ToolsKey.include],
        key: "\(context).\(ToolsKey.include)"
      ),
      exclude: try stringList(
        mapping[ToolsKey.exclude],
        key: "\(context).\(ToolsKey.exclude)"
      ),
      risk: try parseRisk(mapping[ToolsKey.risk], context: "\(context).\(ToolsKey.risk)")
    )
  }

  /// Maps the owner's tier words onto `RiskLevel`. `dangerous` parses here and is refused by
  /// `MCPServerConfig`, so the refusal names the tier rather than reading as a spelling mistake.
  static func parseRisk(_ raw: Any?, context: String) throws -> [String: RiskLevel] {
    let entries = try optionalStringMap(raw, key: context)
    var risk: [String: RiskLevel] = [:]
    for (tool, rawLevel) in entries {
      guard let level = RiskLevel(rawValue: rawLevel) else {
        throw MCPConfigError.invalidValue(key: "\(context).\(tool)", value: rawLevel)
      }
      risk[tool] = level
    }
    return risk
  }
}

// MARK: - Scalar Decoding

private extension MCPConfigLoader {
  /// YAML's explicit null (`key:` with no value) decodes to `NSNull`, which every caller here means
  /// as "the owner left it out".
  static func unwrapped(_ raw: Any?) -> Any? {
    guard let raw, raw is NSNull == false else {
      return nil
    }
    return raw
  }

  static func requireKnownKeys(
    in mapping: [String: Any],
    allowed: Set<String>,
    context: String?
  ) throws {
    for key in mapping.keys.sorted() where allowed.contains(key) == false {
      throw MCPConfigError.unknownKey(context.map { "\($0).\(key)" } ?? key)
    }
  }

  static func requiredString(_ raw: Any?, key: String) throws -> String {
    guard let value = try optionalString(raw, key: key) else {
      throw MCPConfigError.missingValue(key: key)
    }
    return value
  }

  static func optionalString(_ raw: Any?, key: String) throws -> String? {
    guard let raw = unwrapped(raw) else {
      return nil
    }
    guard let value = raw as? String else {
      throw MCPConfigError.invalidValue(key: key, value: "expected a string")
    }
    return value
  }

  static func boolValue(_ raw: Any?, key: String, default fallback: Bool) throws -> Bool {
    guard let raw = unwrapped(raw) else {
      return fallback
    }
    guard let value = raw as? Bool else {
      throw MCPConfigError.invalidValue(key: key, value: "expected true or false")
    }
    return value
  }

  static func optionalInt(_ raw: Any?, key: String) throws -> Int? {
    guard let raw = unwrapped(raw) else {
      return nil
    }
    guard let value = raw as? Int else {
      throw MCPConfigError.invalidValue(key: key, value: "expected an integer")
    }
    return value
  }

  // nil and [] encode different include-filter policies.
  // swiftlint:disable:next discouraged_optional_collection
  static func presentStringList(_ raw: Any?, key: String) throws -> [String]? {
    guard let raw = unwrapped(raw) else {
      return nil
    }
    guard let entries = raw as? [Any] else {
      throw MCPConfigError.invalidValue(key: key, value: "expected a list of strings")
    }
    return try entries.map { entry in
      guard let value = entry as? String else {
        throw MCPConfigError.invalidValue(key: key, value: "expected a list of strings")
      }
      return value
    }
  }

  static func stringList(_ raw: Any?, key: String) throws -> [String] {
    try presentStringList(raw, key: key) ?? []
  }

  static func optionalStringMap(_ raw: Any?, key: String) throws -> [String: String] {
    guard let raw = unwrapped(raw) else {
      return [:]
    }
    guard let mapping = raw as? [String: Any] else {
      throw MCPConfigError.invalidValue(key: key, value: "expected a mapping of strings")
    }
    var result: [String: String] = [:]
    for (entryKey, entryValue) in mapping {
      guard let value = entryValue as? String else {
        throw MCPConfigError.invalidValue(key: "\(key).\(entryKey)", value: "expected a string")
      }
      result[entryKey] = value
    }
    return result
  }
}
