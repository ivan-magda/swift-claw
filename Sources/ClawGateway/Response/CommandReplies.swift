import ClawCore

public enum CommandReplies {
  public static let stopped = "Stopped."
  public static let nothingToStop = "Nothing to stop."
  public static let freshConversation =
    "Started a fresh conversation — earlier context cleared."

  /// Refusal for the owner-scoped command families in a shared room. It names the private state so
  /// the attendee learns the rule, not just this one rejection.
  public static let directOnly =
    "Not here — memory, schedules, and learning state live in my owner's direct chat."

  public static let learningUsage = "Usage: /learning reset <id>. See /learning"
  public static let learningResetUnavailable =
    "Learning reset is not available in this build."
  public static let learningUnavailable = "Learning status is unavailable. Try again."

  /// The owner manual, including the parked-entry interaction rules (stated verbatim as
  /// owner-visible text): slash commands bypass confirmation resolution entirely; only the
  /// next plain text resolves a parked entry; /new clears it; a second /schedule displaces it;
  /// /stop and /new act on the interactive session only.
  public static let help = """
    Commands:
    /schedule <text>: create a schedule (I confirm before it arms)
    /schedule list: list schedules
    /pause <id> · /resume <id> · /runnow <id> · /cancel <id>: manage schedules
    /learning · /learning <id>: inspect scheduled-job learning
    /learning reset <id>: reset learning (not available in this build)
    /remember, /memory: durable memory
    /new: fresh conversation · /stop: stop the current run
    /status: daemon health (also /doctor) · /mcp: MCP server status
    /skills: accepted and rejected workspace skills

    Confirmations:
    Slash commands never resolve a pending confirmation. Only your next plain-text \
    message does: "yes" confirms, "no" or "cancel" rejects, anything else drops it. \
    /new also clears a pending confirmation, and a second /schedule replaces a parked \
    draft. /stop and /new act on this chat only, never on scheduled job sessions. \
    Stop a job's future fires with /cancel <id>.
    """

  /// The room's manual. It lists only what a topic can actually use: the owner-scoped families are
  /// refused here, and no confirmation can park in a room, so printing either would document a
  /// surface an attendee is then told off for touching.
  static let groupHelp = """
    Commands:
    /new: fresh conversation in this topic · /stop: stop the current run
    /status: daemon health (also /doctor) · /mcp: MCP server status
    /skills: accepted and rejected workspace skills

    Mention me or reply to me to ask something; I read the topic either way.
    Memory, schedules, and learning state live in my owner's direct chat, not here.
    """

  /// The manual this conversation can act on.
  static func help(mode: ChatMode) -> String {
    switch mode {
    case .direct: help
    case .group: groupHelp
    }
  }
}
