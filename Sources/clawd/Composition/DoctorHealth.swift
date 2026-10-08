import ClawCore
import ClawData
import ClawGateway
import ClawWorkspace
import Foundation

enum DoctorHealth {
  static func checks(
    stores: ClawStores,
    config: AppConfig,
    now: Date,
    routeHealth: LLMRouteHealth
  ) -> [DoctorReport.Check] {
    HealthRowsBuilder.checks(
      inputs(stores: stores, config: config, now: now, routeHealth: routeHealth)
    )
      + schedulerChecks(stores: stores, config: config, now: now)
      + approvalChecks(stores: stores, config: config, now: now)
      + journalChecks(stores: stores, config: config, now: now)
  }

  static func journalConfigChecks(config: AppConfig) -> [DoctorReport.Check] {
    JournalHealth.configRows(policy: config.journalPolicy)
  }

  static func journalChecks(
    stores: ClawStores,
    config: AppConfig,
    now: Date
  ) -> [DoctorReport.Check] {
    let status: HealthValue<JournalStatus>
    if let ownerUserID = config.journalPolicy.ownerUserID {
      status = read { try stores.journal.status(ownerUserID: ownerUserID, now: now) }
    } else {
      status = .available(
        JournalStatus(
          pendingCount: 0,
          lastOutcome: nil,
          lastOutcomeAt: nil,
          skippedCount: 0,
          interruptedCount: 0,
          lastRedactedError: nil
        )
      )
    }
    return JournalHealth.rows(policy: config.journalPolicy, status: status)
  }

  static func inputs(
    stores: ClawStores,
    config: AppConfig,
    now: Date,
    routeHealth: LLMRouteHealth
  ) -> HealthRowsBuilder.Inputs {
    let skillDiagnostics = SkillDiagnostics(
      scan: skillScan(config: config),
      skillsCap: ContextBudget.default.skillsCap
    )

    let dbPath = EnvironmentLoader.databasePath(config: config)
    let walBytes =
      (try? FileManager.default.attributesOfItem(atPath: dbPath + "-wal")[.size] as? Int) ?? 0
    let fileSystem = try? FileManager.default.attributesOfFileSystem(forPath: config.stateRoot.path)
    let freeBytes = (fileSystem?[.systemFreeSize] as? Int) ?? 0
    let prices = routePrices(config: config)

    return HealthRowsBuilder.Inputs(
      allowlist: AllowlistHealth(
        seeded: try? stores.allowlist.allowlistCount(),
        configured: config.allowlist.count
      ),
      lastOffset: try? stores.cursor.loadCursor(),
      runsHealth: read {
        try stores.runs.runsHealth(now: now)
      },
      routeHealth: routeHealth,
      retryBudget: config.llm.retryBudget,
      streamingEnabled: config.llm.streamingEnabled,
      todayUsage: read {
        try stores.usage.todayTokensAndCost(now: now)
      },
      costMix: read {
        try stores.usage.costSourceMix(now: now)
      },
      primaryPrice: prices.primary,
      fallbackPrice: prices.fallback,
      perDayUSD: config.budget.perDayUSD,
      perRunUSD: config.budget.perRunUSD,
      walBytes: walBytes,
      freeBytes: freeBytes,
      latestContext: read {
        try stores.usage.latestPromptUsage()
      },
      skillDiagnostics: skillDiagnostics
    )
  }

  static func skillScan(config: AppConfig) -> SkillScanResult {
    FileSystemWorkspace(root: EnvironmentLoader.workspaceRoot(config: config)).scanSkills()
  }

  /// The price rows `doctor --check-config` prints. Full doctor and `/status` render the same rows
  /// through `inputs`.
  static func priceChecks(config: AppConfig) -> [DoctorReport.Check] {
    let prices = routePrices(config: config)
    return HealthRowsBuilder.priceChecks(primary: prices.primary, fallback: prices.fallback)
  }

  /// Each configured route's price, read from the resolver the daemon meters with.
  static func routePrices(
    config: AppConfig
  ) -> (primary: RoutePriceHealth, fallback: RoutePriceHealth?) {
    let resolver = CostResolver.configured(by: config)
    let fallback = config.llm.fallbackRoute.map { route in
      RoutePriceHealth(route: route, resolver: resolver)
    }
    return (RoutePriceHealth(route: config.llm.route, resolver: resolver), fallback)
  }

  static func schedulerChecks(
    stores: ClawStores,
    config: AppConfig,
    now: Date
  ) -> [DoctorReport.Check] {
    let snapshot = SchedulerHealth.Snapshot(
      state: read {
        try stores.scheduledJobs.schedulerState()
      },
      dueCount: read {
        try stores.scheduledJobs.dueJobs(now: now).count
      },
      proactiveTodayUSD: read {
        try stores.usage.todayTokensAndCost(origins: RunOrigin.proactiveOrigins, now: now).costUSD
      },
      proactivePerDayUSD: config.budget.proactivePerDayUSD,
      heartbeatEnabled: config.heartbeatEnabled,
      heartbeatMaxPerDay: config.heartbeatMaxPerDay,
      timezone: config.timezone,
      now: now
    )

    return SchedulerHealth.rows(snapshot)
  }

  static func approvalChecks(
    stores: ClawStores,
    config: AppConfig,
    now: Date
  ) -> [DoctorReport.Check] {
    return ApprovalsHealthRows.rows(
      health: read {
        try stores.approvals.approvalsHealth(now: now)
      },
      approvalExpirySeconds: config.approvalExpirySeconds
    )
  }

  static func bootSandboxChecks(
    execEnabled: Bool,
    health: SandboxHealth?,
    unavailableReason: String?
  ) -> [DoctorReport.Check] {
    let status = SandboxDoctorStatus.atBoot(
      execEnabled: execEnabled,
      health: health,
      unavailableReason: unavailableReason
    )
    return SandboxHealthRows.rows(for: status)
  }
}

// MARK: - Health Store Reads

private extension DoctorHealth {
  static func read<Value: Sendable>(_ load: () throws -> Value) -> HealthValue<Value> {
    do {
      return .available(try load())
    } catch {
      return .unavailable
    }
  }
}
