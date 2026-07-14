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

public enum HealthRowsBuilder {
  public struct Inputs: Sendable {
    public let allowlist: AllowlistHealth
    public let lastOffset: Int64?
    public let runsHealth: RunsHealth
    public let retryBudget: Int
    public let streamingEnabled: Bool
    public let todayTokens: Int
    public let todayUSD: Double
    public let costMix: [CostSource: Int]
    public let perDayUSD: Double
    public let perRunUSD: Double
    public let walBytes: Int
    public let freeBytes: Int

    public init(
      allowlist: AllowlistHealth,
      lastOffset: Int64?,
      runsHealth: RunsHealth,
      retryBudget: Int,
      streamingEnabled: Bool,
      todayTokens: Int,
      todayUSD: Double,
      costMix: [CostSource: Int],
      perDayUSD: Double,
      perRunUSD: Double,
      walBytes: Int,
      freeBytes: Int
    ) {
      self.allowlist = allowlist
      self.lastOffset = lastOffset
      self.runsHealth = runsHealth
      self.retryBudget = retryBudget
      self.streamingEnabled = streamingEnabled
      self.todayTokens = todayTokens
      self.todayUSD = todayUSD
      self.costMix = costMix
      self.perDayUSD = perDayUSD
      self.perRunUSD = perRunUSD
      self.walBytes = walBytes
      self.freeBytes = freeBytes
    }
  }

  public static func checks(_ inputs: Inputs) -> [DoctorReport.Check] {
    databaseChecks(inputs) + runChecks(inputs) + spendChecks(inputs) + storageChecks(inputs)
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
