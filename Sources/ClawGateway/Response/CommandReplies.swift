public enum CommandReplies {
  public static let stopped = "Stopped."
  public static let nothingToStop = "Nothing to stop."
  public static let freshConversation =
    "Started a fresh conversation — earlier context cleared."

  /// The owner manual, including the parked-entry interaction rules (stated verbatim as
  /// owner-visible text): slash commands bypass confirmation resolution entirely; only the
  /// next plain text resolves a parked entry; /new clears it; a second /schedule displaces it;
  /// /stop and /new act on the interactive session only.
  public static let help = """
    Commands:
    /schedule <text>: create a schedule (I confirm before it arms)
    /schedule list: list schedules
    /pause <id> · /resume <id> · /runnow <id> · /cancel <id>: manage schedules
    /remember, /memory: durable memory
    /new: fresh conversation · /stop: stop the current run
    /status: daemon health (also /doctor)

    Confirmations:
    Slash commands never resolve a pending confirmation. Only your next plain-text \
    message does: "yes" confirms, "no" or "cancel" rejects, anything else drops it. \
    /new also clears a pending confirmation, and a second /schedule replaces a parked \
    draft. /stop and /new act on this chat only, never on scheduled job sessions. \
    Stop a job's future fires with /cancel <id>.
    """
}
