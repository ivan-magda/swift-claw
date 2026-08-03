import ClawCore

/// One remote tool as the owner's config declares it: the server it belongs to, and the name that
/// server calls it. Owner-facing config always speaks this vocabulary, never the composed name.
public struct MCPToolCoordinate: Sendable, Equatable, Hashable {
  public let server: String
  public let remoteName: String

  public init(server: String, remoteName: String) {
    self.server = server
    self.remoteName = remoteName
  }
}

/// A remote tool paired with the local name the registry advertises for it.
public struct MCPToolNaming: Sendable, Equatable {
  public let coordinate: MCPToolCoordinate
  public let localName: String

  public init(coordinate: MCPToolCoordinate, localName: String) {
    self.coordinate = coordinate
    self.localName = localName
  }
}

/// Composes registry names for remote tools.
///
/// `ToolRegistry` traps on a duplicate name, so naming has to be total before construction: every
/// remote name folds into the charset, both caps are enforced by truncation rather than rejection,
/// and a collision that survives all that gets a numeric suffix. The `mcp__` prefix is what makes a
/// collision with a built-in structurally impossible — no built-in carries it.
///
/// Names are assigned across the whole declared set in one pass, in config order, so a server added
/// at the end of the file cannot silently rename an earlier server's tools.
public enum MCPToolNamer {
  public static let prefix = "mcp__"
  public static let separator = "__"
  /// Caps the server fragment so one verbose server name cannot crowd out every tool name behind it.
  public static let serverFragmentLimit = 30
  public static let nameLimit = 64

  public static func assign(_ coordinates: [MCPToolCoordinate]) -> [MCPToolNaming] {
    var taken: Set<String> = []
    var assigned: [MCPToolNaming] = []
    assigned.reserveCapacity(coordinates.count)

    for coordinate in coordinates {
      let base = composed(server: coordinate.server, tool: coordinate.remoteName)
      assigned.append(
        MCPToolNaming(coordinate: coordinate, localName: unique(base, taken: &taken))
      )
    }

    return assigned
  }
}

// MARK: - Composition

private extension MCPToolNamer {
  /// Fallbacks for a fragment that folds away to nothing: a name is still required, and a stable
  /// placeholder plus the collision suffix keeps the set unambiguous.
  enum Fallback {
    static let server = "server"
    static let tool = "tool"
  }

  static func composed(server: String, tool: String) -> String {
    let head =
      prefix + fragment(server, fallback: Fallback.server, limit: serverFragmentLimit)
      + separator
    let available = max(nameLimit - head.count, 1)

    return head + fragment(tool, fallback: Fallback.tool, limit: available)
  }

  static func fragment(_ raw: String, fallback: String, limit: Int) -> String {
    let sanitized = MCPNaming.sanitizeFragment(raw)
    let usable = sanitized.isEmpty ? fallback : sanitized

    return String(usable.prefix(limit))
  }

  /// Appends the lowest free numeric suffix, trimming the base to keep the total under the cap.
  static func unique(_ base: String, taken: inout Set<String>) -> String {
    guard taken.insert(base).inserted == false else {
      return base
    }

    var counter = 2
    while true {
      let suffix = "_\(counter)"
      let candidate = String(base.prefix(max(nameLimit - suffix.count, 0))) + suffix
      if taken.insert(candidate).inserted {
        return candidate
      }
      counter += 1
    }
  }
}
