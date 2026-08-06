import ClawCore
import Foundation

public struct AllowlistHealth: Sendable, Equatable {
  public let seeded: Int?
  public let configured: Int

  public init(seeded: Int?, configured: Int) {
    self.seeded = seeded
    self.configured = configured
  }
}

/// The route picture the doctor reports: which route is configured as primary, which fallback (if
/// any) stands behind it, and what the reader can say about the primary's cooldown window.
public struct LLMRouteHealth: Sendable, Equatable {
  /// The windows live in the running daemon's memory, so a reader outside that process can only
  /// say that it does not know — never that the primary is clear.
  public enum Cooldown: Sendable, Equatable {
    case clear
    case cooling(remainingSeconds: Int)
    case unobservable
  }

  public let primaryReference: String
  public let fallbackReference: String?
  public let cooldown: Cooldown

  public init(primaryReference: String, fallbackReference: String?, cooldown: Cooldown) {
    self.primaryReference = primaryReference
    self.fallbackReference = fallbackReference
    self.cooldown = cooldown
  }

  /// Reads the live window from the cooldown the daemon composed, so the rows report the same
  /// state the next turn will route on.
  public static func live(
    primaryReference: String,
    fallbackReference: String?,
    cooldown: any RouteCooldownTracking
  ) async -> LLMRouteHealth {
    let remaining = await cooldown.remainingSeconds(routeIndex: 0)
    return LLMRouteHealth(
      primaryReference: primaryReference,
      fallbackReference: fallbackReference,
      cooldown: remaining.map { seconds in .cooling(remainingSeconds: seconds) } ?? .clear
    )
  }
}

public enum HealthRowsBuilder {
  public struct Inputs: Sendable {
    public let allowlist: AllowlistHealth
    public let lastOffset: Int64?
    public let runsHealth: RunsHealth
    public let routeHealth: LLMRouteHealth
    public let retryBudget: Int
    public let streamingEnabled: Bool
    public let todayTokens: Int
    public let todayUSD: Double
    public let costMix: [CostSource: Int]
    public let perDayUSD: Double
    public let perRunUSD: Double
    public let walBytes: Int
    public let freeBytes: Int
    public let latestContext: LatestPromptUsage?

    public init(
      allowlist: AllowlistHealth,
      lastOffset: Int64?,
      runsHealth: RunsHealth,
      routeHealth: LLMRouteHealth,
      retryBudget: Int,
      streamingEnabled: Bool,
      todayTokens: Int,
      todayUSD: Double,
      costMix: [CostSource: Int],
      perDayUSD: Double,
      perRunUSD: Double,
      walBytes: Int,
      freeBytes: Int,
      latestContext: LatestPromptUsage?
    ) {
      self.allowlist = allowlist
      self.lastOffset = lastOffset
      self.runsHealth = runsHealth
      self.routeHealth = routeHealth
      self.retryBudget = retryBudget
      self.streamingEnabled = streamingEnabled
      self.todayTokens = todayTokens
      self.todayUSD = todayUSD
      self.costMix = costMix
      self.perDayUSD = perDayUSD
      self.perRunUSD = perRunUSD
      self.walBytes = walBytes
      self.freeBytes = freeBytes
      self.latestContext = latestContext
    }
  }

  public static func checks(_ inputs: Inputs) -> [DoctorReport.Check] {
    databaseChecks(inputs)
      + runChecks(inputs)
      + routeChecks(inputs.routeHealth)
      + contextChecks(inputs)
      + spendChecks(inputs)
      + storageChecks(inputs)
  }

  /// The one spelling of the fallback row, so the config-only doctor path and the live health table
  /// can never disagree about the key or the wording.
  public static func fallbackConfiguredCheck(fallbackReference: String?) -> DoctorReport.Check {
    check(
      "llm.fallback_configured",
      fallbackReference.map { reference in "yes (\(reference))" } ?? "no",
      .llmRuns
    )
  }
}

// MARK: - Group Builders

private extension HealthRowsBuilder {
  static func databaseChecks(_ inputs: Inputs) -> [DoctorReport.Check] {
    let owners = ownersOutcome(inputs.allowlist)
    return [
      DoctorReport.Check(
        key: "allowlist.owners",
        value: owners.value,
        ok: owners.ok,
        group: .database
      ),
      DoctorReport.Check(
        key: "poller.last_offset",
        value: inputs.lastOffset.map(String.init) ?? "none",
        ok: true,
        group: .database
      ),
    ]
  }

  static func ownersOutcome(_ owners: AllowlistHealth) -> (value: String, ok: Bool) {
    guard let seeded = owners.seeded else {
      return ("unreadable (db read failed)", false)
    }

    if seeded >= 1 {
      return ("\(seeded)", true)
    }

    if owners.configured >= 1 {
      return ("0 seeded, \(owners.configured) configured (seeded at daemon start)", true)
    }

    return ("0", false)
  }

  static func runChecks(_ inputs: Inputs) -> [DoctorReport.Check] {
    let health = inputs.runsHealth
    return [
      check(
        "llm.last_success",
        health.lastSuccessAt.map(String.init(describing:)) ?? "never",
        .llmRuns
      ),
      check("llm.consecutive_failures", "\(health.consecutiveFailures)", .llmRuns, headline: true),
      check("llm.retry_budget", "\(inputs.retryBudget)", .llmRuns),
      check("llm.streaming", inputs.streamingEnabled ? "on" : "off", .llmRuns),
      check("runs.in_flight", "\(health.inFlight)", .llmRuns, headline: true),
      check(
        "runs.oldest_age_s",
        health.oldestRunAgeSeconds.map { String(format: "%.0f", $0) } ?? "none",
        .llmRuns
      ),
      check(
        "runs.last_FAILED",
        health.lastFailedAt.map(String.init(describing:)) ?? "none",
        .llmRuns
      ),
    ]
  }

  /// Which model is answering is the one route fact an owner asks for by name, so `active_route`
  /// rides the group line into the Telegram summary, which keeps only headlines. The window is a
  /// headline **only while one is live**: `none` on every healthy turn would spend a summary slot on
  /// a state that says nothing, and a live window is exactly when the seconds are worth reading.
  static func routeChecks(_ health: LLMRouteHealth) -> [DoctorReport.Check] {
    let isCooling: Bool
    if case .cooling = health.cooldown {
      isCooling = true
    } else {
      isCooling = false
    }

    return [
      check("llm.active_route", activeRoute(health), .llmRuns, headline: true),
      fallbackConfiguredCheck(fallbackReference: health.fallbackReference),
      check(
        "llm.primary_cooldown_s",
        cooldownSeconds(health.cooldown),
        .llmRuns,
        headline: isCooling
      ),
    ]
  }

  /// The route the next turn starts on — not one proven healthy. Only the primary's window is ever
  /// armed, so a fallback that is itself failing looks the same here; the failure counters above
  /// are what report that.
  static func activeRoute(_ health: LLMRouteHealth) -> String {
    switch health.cooldown {
    case .clear:
      return health.primaryReference
    case .cooling:
      let answering = health.fallbackReference ?? health.primaryReference
      return "\(answering) (primary \(health.primaryReference) cooling)"
    case .unobservable:
      return "\(health.primaryReference) (configured primary)"
    }
  }

  static func cooldownSeconds(_ cooldown: LLMRouteHealth.Cooldown) -> String {
    switch cooldown {
    case .clear: "none"
    case .cooling(let remainingSeconds): "\(remainingSeconds)"
    case .unobservable: "unknown"
    }
  }

  static func contextChecks(_ inputs: Inputs) -> [DoctorReport.Check] {
    let value =
      inputs.latestContext.map { context in
        let tokens = "\(context.isEstimated ? "~" : "")\(context.promptTokens)"
        return context.runId.map { runId in
          "\(tokens) (run \(runId))"
        } ?? tokens
      } ?? "none"
    return [
      check(
        "context.last_prompt_tokens",
        value,
        .context,
        headline: true
      )
    ]
  }

  static func spendChecks(_ inputs: Inputs) -> [DoctorReport.Check] {
    let mixText =
      inputs.costMix
      .map { entry in "\(entry.key.rawValue)=\(entry.value)" }
      .sorted()
      .joined(separator: " ")
    return [
      check("spend.today_usd", USD.precise(inputs.todayUSD), .spend, headline: true),
      check("spend.today_tokens", "\(inputs.todayTokens)", .spend),
      check(
        "spend.remaining_day_usd",
        USD.display(max(0, inputs.perDayUSD - inputs.todayUSD)),
        .spend,
        headline: true
      ),
      check("spend.per_run_cap_usd", USD.display(inputs.perRunUSD), .spend),
      check("spend.cost_source_mix", mixText.isEmpty ? "none" : mixText, .spend),
    ]
  }

  static func storageChecks(_ inputs: Inputs) -> [DoctorReport.Check] {
    [
      check("db.wal_size", "\(inputs.walBytes)", .storage),
      DoctorReport.Check(
        key: "db.free_disk",
        value: "\(inputs.freeBytes)",
        ok: inputs.freeBytes > 0,
        group: .storage
      ),
    ]
  }

  static func check(
    _ key: String,
    _ value: String,
    _ group: DoctorGroup,
    headline: Bool = false
  ) -> DoctorReport.Check {
    DoctorReport.Check(key: key, value: value, ok: true, group: group, isHeadline: headline)
  }
}
