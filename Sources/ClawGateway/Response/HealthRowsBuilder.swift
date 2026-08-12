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
    cooldown: any PrimaryRouteCooldownTracking
  ) async -> LLMRouteHealth {
    let remaining = await cooldown.remainingSeconds()
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
    public let runsHealth: HealthValue<RunsHealth>
    public let routeHealth: LLMRouteHealth
    public let retryBudget: Int
    public let streamingEnabled: Bool
    public let todayUsage: HealthValue<(tokens: Int, costUSD: Double)>
    public let costMix: HealthValue<[CostSource: Int]>
    public let perDayUSD: Double
    public let perRunUSD: Double
    public let walBytes: Int
    public let freeBytes: Int
    public let latestContext: HealthValue<LatestPromptUsage?>
    public let skillDiagnostics: SkillDiagnostics

    public init(
      allowlist: AllowlistHealth,
      lastOffset: Int64?,
      runsHealth: HealthValue<RunsHealth>,
      routeHealth: LLMRouteHealth,
      retryBudget: Int,
      streamingEnabled: Bool,
      todayUsage: HealthValue<(tokens: Int, costUSD: Double)>,
      costMix: HealthValue<[CostSource: Int]>,
      perDayUSD: Double,
      perRunUSD: Double,
      walBytes: Int,
      freeBytes: Int,
      latestContext: HealthValue<LatestPromptUsage?>,
      skillDiagnostics: SkillDiagnostics
    ) {
      self.allowlist = allowlist
      self.lastOffset = lastOffset
      self.runsHealth = runsHealth
      self.routeHealth = routeHealth
      self.retryBudget = retryBudget
      self.streamingEnabled = streamingEnabled
      self.todayUsage = todayUsage
      self.costMix = costMix
      self.perDayUSD = perDayUSD
      self.perRunUSD = perRunUSD
      self.walBytes = walBytes
      self.freeBytes = freeBytes
      self.latestContext = latestContext
      self.skillDiagnostics = skillDiagnostics
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

  static func skillsCheck(_ diagnostics: SkillDiagnostics) -> DoctorReport.Check {
    DoctorReport.Check(
      key: "context.skills",
      value: "accepted=\(diagnostics.acceptedCount) rejected=\(diagnostics.rejectedCount) "
        + "fits_cap=\(diagnostics.fitsSkillsCap)",
      ok: diagnostics.rejectedCount == 0 && diagnostics.fitsSkillsCap,
      group: .context,
      isHeadline: true
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
      return (DoctorReport.Check.storeReadFailureValue, false)
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
    [
      .storeRead(inputs.runsHealth, key: "llm.last_success", group: .llmRuns) { health in
        health.lastSuccessAt.map(String.init(describing:)) ?? "never"
      },
      .storeRead(
        inputs.runsHealth,
        key: "llm.consecutive_failures",
        group: .llmRuns,
        isHeadline: true
      ) { health in
        "\(health.consecutiveFailures)"
      },
      check("llm.retry_budget", "\(inputs.retryBudget)", .llmRuns),
      check("llm.streaming", inputs.streamingEnabled ? "on" : "off", .llmRuns),
      .storeRead(
        inputs.runsHealth,
        key: "runs.in_flight",
        group: .llmRuns,
        isHeadline: true
      ) { health in
        "\(health.inFlight)"
      },
      .storeRead(inputs.runsHealth, key: "runs.oldest_age_s", group: .llmRuns) { health in
        health.oldestRunAgeSeconds.map { String(format: "%.0f", $0) } ?? "none"
      },
      .storeRead(inputs.runsHealth, key: "runs.last_FAILED", group: .llmRuns) { health in
        health.lastFailedAt.map(String.init(describing:)) ?? "none"
      },
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
    [
      .storeRead(
        inputs.latestContext,
        key: "context.last_prompt_tokens",
        group: .context,
        isHeadline: true
      ) { latestContext in
        latestContext.map { context in
          let tokens = "\(context.isEstimated ? "~" : "")\(context.promptTokens)"
          return context.runId.map { runId in
            "\(tokens) (run \(runId))"
          } ?? tokens
        } ?? "none"
      },
      skillsCheck(inputs.skillDiagnostics),
    ]
  }

  static func spendChecks(_ inputs: Inputs) -> [DoctorReport.Check] {
    [
      .storeRead(
        inputs.todayUsage,
        key: "spend.today_usd",
        group: .spend,
        isHeadline: true
      ) { usage in
        USD.precise(usage.costUSD)
      },
      .storeRead(inputs.todayUsage, key: "spend.today_tokens", group: .spend) { usage in
        "\(usage.tokens)"
      },
      .storeRead(
        inputs.todayUsage,
        key: "spend.remaining_day_usd",
        group: .spend,
        isHeadline: true
      ) { usage in
        USD.display(max(0, inputs.perDayUSD - usage.costUSD))
      },
      check("spend.per_run_cap_usd", USD.display(inputs.perRunUSD), .spend),
      .storeRead(inputs.costMix, key: "spend.cost_source_mix", group: .spend) { costMix in
        let text =
          costMix
          .map { entry in
            "\(entry.key.rawValue)=\(entry.value)"
          }
          .sorted()
          .joined(separator: " ")
        return text.isEmpty ? "none" : text
      },
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
