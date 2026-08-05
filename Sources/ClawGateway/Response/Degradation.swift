import ClawAgent

/// The user-visible, plain-language replies for every way a turn can fail to produce a usable
/// answer. The contract is "never silence": every failure path enqueues one of these so the
/// owner always hears back. Strings live here (not in the prompt) so they're testable and uniform.
public enum Degradation {
  public static let providerUnavailable =
    "I couldn't reach the model. Please try again in a moment."
  public static let outputTruncated =
    "The model hit its output limit before answering. Try a shorter prompt."
  public static let contextUnavailable =
    "I couldn't build the context for this turn. Please trim workspace memory or try again."
  /// Used by boot reconciliation for a run that crashed mid-turn without delivering anything.
  public static let unfinished = "I didn't finish your last request. Please resend it."
  /// Used on the `SQLITE_FULL` path when the message can't even be persisted.
  public static let storageFull =
    "Storage is full, so I can't save messages. Please free up disk space."
  /// Used when a mid-run usage/audit write fails non-fatally; the run halts rather than spend
  /// further without a durable record.
  public static let accountingFailed =
    "I hit an internal storage problem and stopped to be safe. Please try again."

  /// The credential is gone or refused. The sentence names the exact recovery — the daemon must be
  /// stopped, re-authenticated, and started again, because a running daemon holds the process lock.
  /// Pinned verbatim: it is the one degradation reply that tells the owner to log in.
  public static let authenticationRequired =
    "ChatGPT authentication is required. Stop clawd, run `clawd auth login`, then start clawd again."

  /// The subscription/account cannot use the requested route or model. It deliberately does NOT tell
  /// the owner to log in: the credential is valid, so re-authenticating would change nothing.
  public static let accessDenied =
    "Your ChatGPT plan can't use the requested model or route. Logging in again won't change that — "
    + "adjust the configured model or your plan."

  /// Replay state the route rejected. Safe `/new` guidance: a fresh session drops the state, and the
  /// rejected attempt is never re-issued.
  public static let invalidProviderState =
    "I lost the thread of this conversation. Send /new to start fresh, then try again."

  /// The route refused the image because the model cannot see. Resending changes nothing, so the
  /// sentence names the cause rather than inviting a retry. `/new` leads because it is the only
  /// remedy that works right now: the photo stays in the history window until the conversation is
  /// reset, so every following question — image or not — comes back with this same refusal, while
  /// both config knobs need an edit and a daemon restart before they change anything.
  public static let visionUnsupported =
    "The model you've configured can't look at images. Send /new — otherwise that photo stays in "
    + "this conversation and every question after it gets this same reply. To fix it for good, set "
    + "`CLAW_LLM_MODEL` to a vision-capable model, or set `CLAW_IMAGE_INPUT=false` to stop sending "
    + "photos."

  /// A clean throttle. Says to retry after the provider's bounded hint when it gave one, else after
  /// the plan resets — never to log in. The hint is a structured number the provider returned, not
  /// remote free text, so echoing the count interpolates no untrusted string.
  public static func quotaLimited(retryAfterSeconds: Int?) -> String {
    if let retryAfterSeconds {
      return "That hit ChatGPT's rate limit. Try again in \(retryAfterSeconds) seconds, "
        + "or after your plan's quota resets."
    }
    return "That hit ChatGPT's rate limit. Try again after your plan's quota resets."
  }

  /// The spend-breaker reply; `cap` names the tripped limit (e.g. "per-run spend" / "per-day token").
  public static func budget(cap: String) -> String {
    "I stopped because I hit the \(cap) cap."
  }

  /// The once-per-UTC-day owner DM fired by the post-commit kill-switch (`BudgetBreaker`).
  public static let dailyCapTripped =
    "Heads up — the daily spend cap was reached, so I've paused new requests until the next UTC day."

  /// The once-per-UTC-day owner DM for a proactive-cap trip. Names the cap explicitly and
  /// says interactive use is unaffected, so the owner knows the household kill-switch did NOT trip.
  public static let proactiveCapTripped =
    "Heads up — scheduled/heartbeat runs hit the proactive per-day spend cap and are paused until the next UTC day. Interactive use is unaffected."

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
    case .authenticationRequired:
      return authenticationRequired
    case .accessDenied:
      return accessDenied
    case .quotaLimited(let retryAfterSeconds):
      return quotaLimited(retryAfterSeconds: retryAfterSeconds)
    case .invalidProviderState:
      return invalidProviderState
    case .visionUnsupported:
      return visionUnsupported
    }
  }

  /// The one-time notice that a turn was answered by a route other than the configured primary.
  /// It names both routes because the owner's next question is which model actually replied, and
  /// because a metered fallback behind a flat-rate primary is a spend change they should see.
  public static func routeSwitched(from primary: String, to fallback: String) -> String {
    "Heads up — \(primary) couldn't answer, so I used \(fallback) for this reply."
  }

  /// The matching notice when the primary answers again.
  public static func routeRestored(route: String) -> String {
    "\(route) is answering again."
  }

  /// Appended to a degraded reply when the turn already switched routes and the fallback then
  /// failed too, so the reply names the primary's cause without implying the fallback was never
  /// tried.
  public static let fallbackAlsoFailed = "I tried the backup model too, and it also failed."

  /// Maps a route transition to its owner-facing notice. Exhaustive over `RouteNotice`, so a new
  /// case forces a deliberate copy decision here.
  public static func message(for notice: RouteNotice) -> String {
    switch notice {
    case .switched(let primary, let fallback):
      return routeSwitched(from: primary, to: fallback)
    case .restored(let route):
      return routeRestored(route: route)
    }
  }
}
