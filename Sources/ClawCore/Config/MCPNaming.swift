/// The shared naming vocabulary for MCP servers and their tools.
///
/// Config validation and the tool namer have to fold a name the same way, or the daemon accepts a
/// catalog whose composed tool names then collide.
public enum MCPNaming {
  private static let allowed = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
  )

  /// Maps one name fragment into the tool-name charset, character for character so the fold stays
  /// deterministic and reversible enough for an owner to recognize their server in a prompt.
  public static func sanitizeFragment(_ raw: String) -> String {
    String(raw.map { allowed.contains($0) ? $0 : "_" })
  }
}
