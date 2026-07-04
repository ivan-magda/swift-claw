import ClawAgent

/// The user-visible, plain-language replies for every way a turn can fail to produce a usable
/// answer. The contract (§7) is "never silence": every failure path enqueues one of these so the
/// owner always hears back. Strings live here (not in the prompt) so they're testable and uniform.
public enum Degradation {
  public static let providerUnavailable =
    "I couldn't reach the model. Please try again in a moment."
  public static let outputTruncated =
    "The model hit its output limit before answering. Try a shorter prompt."
  public static let contextUnavailable =
    "I couldn't build the context for this turn. Please trim workspace memory or try again."
  /// Used by boot reconciliation (F22) for a run that crashed mid-turn without delivering anything.
  public static let unfinished = "I didn't finish your last request. Please resend it."
  /// Used on the `SQLITE_FULL` path (F23) when the message can't even be persisted.
  public static let storageFull =
    "Storage is full, so I can't save messages. Please free up disk space."
  /// Used when a mid-run usage/audit write fails non-fatally (§6); the run halts rather than spend
  /// further without a durable record.
  public static let accountingFailed =
    "I hit an internal storage problem and stopped to be safe. Please try again."

  /// The spend-breaker reply; `cap` names the tripped limit (e.g. "per-run spend" / "per-day token").
  public static func budget(cap: String) -> String {
    "I stopped because I hit the \(cap) cap."
  }

  /// The once-per-UTC-day owner DM fired by the post-commit kill-switch (`BudgetBreaker`).
  public static let dailyCapTripped =
    "Heads up — the daily spend cap was reached, so I've paused new requests until the next UTC day."

  /// Maps a runtime degradation classification to its owner-facing reply. Exhaustive over
  /// `DegradationKind`, so a new failure mode forces a deliberate copy decision here.
  public static func message(for kind: DegradationKind) -> String {
    switch kind {
    case .providerUnavailable:
      return providerUnavailable
    case .outputTruncated:
      return outputTruncated
    case .contextUnavailable:
      return contextUnavailable
    case .accountingFailed:
      return accountingFailed
    }
  }
}
