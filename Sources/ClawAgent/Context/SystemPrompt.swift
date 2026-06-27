/// The minimal built-in system prompt for Inc 1 (trusted tier). Replaced by SOUL/AGENTS files
/// in Inc 3; the untrusted-tier wrapper is not exercised until then.
public enum SystemPrompt {
  public static let minimal = """
    You are a helpful personal assistant for a single owner, reached over Telegram. \
    Be concise and direct. If you are unsure, say so. Plain text or light Markdown is fine.
    """
}
