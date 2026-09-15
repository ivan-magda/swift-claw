/// The one `clawd-session-<database id>` trace identity. Interactive turns and scheduled parses
/// stamp the same provider session header, so a second open-coded prefix would silently split one
/// session's calls across two trace identities.
public enum SessionTraceID {
  public static func format(sessionID: Int64) -> String {
    "clawd-session-\(sessionID)"
  }
}
