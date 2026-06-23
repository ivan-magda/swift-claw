import ClawAgent

/// The user-visible, plain-language replies for every way a turn can fail to produce a usable
/// answer. The contract (§7) is "never silence": every failure path enqueues one of these so the
/// owner always hears back. Strings live here (not in the prompt) so they're testable and uniform.
public enum Degradation {
  public static let providerUnavailable =
    "I couldn't reach the model. Please try again in a moment."
  public static let outputTruncated =
    "The model hit its output limit before answering. Try a shorter prompt."
  /// Used by boot reconciliation (F22) for a run that crashed mid-turn without delivering anything.
  public static let unfinished = "I didn't finish your last request. Please resend it."
  /// Used on the `SQLITE_FULL` path (F23) when the message can't even be persisted.
  public static let storageFull =
    "Storage is full, so I can't save messages. Please free up disk space."

  /// The spend-breaker reply; `cap` names the tripped limit (e.g. "per-run" / "daily").
  public static func budget(cap: String) -> String {
    "I stopped because I hit the \(cap) cap."
  }

  /// Maps a runtime degradation classification to its owner-facing reply. Exhaustive over
  /// `DegradationKind`, so a new failure mode forces a deliberate copy decision here.
  public static func message(for kind: DegradationKind) -> String {
    switch kind {
    case .providerUnavailable:
      return providerUnavailable
    case .outputTruncated:
      return outputTruncated
    }
  }
}
