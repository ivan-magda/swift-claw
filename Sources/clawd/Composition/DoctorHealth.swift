import ClawCore
import ClawData
import ClawExec
import ClawGateway
import Foundation

enum DoctorHealth {
  static func inputs(
    stores: ClawStores,
    config: AppConfig,
    now: Date,
    routeHealth: LLMRouteHealth
  ) -> HealthRowsBuilder.Inputs {
    let emptyRunsHealth = RunsHealth(
      inFlight: 0,
      oldestRunAgeSeconds: nil,
      lastFailedAt: nil,
      lastSuccessAt: nil,
      consecutiveFailures: 0
    )
    let runsHealth = (try? stores.runs.runsHealth(now: now)) ?? emptyRunsHealth

    let (todayTokens, todayUSD) = (try? stores.usage.todayTokensAndCost(now: now)) ?? (0, 0)
    let costMix = (try? stores.usage.costSourceMix(now: now)) ?? [:]
    let latestContext = try? stores.usage.latestPromptUsage()

    let dbPath = EnvironmentLoader.databasePath(config: config)
    let walBytes =
      (try? FileManager.default.attributesOfItem(atPath: dbPath + "-wal")[.size] as? Int) ?? 0
    let fileSystem = try? FileManager.default.attributesOfFileSystem(forPath: config.stateRoot.path)
    let freeBytes = (fileSystem?[.systemFreeSize] as? Int) ?? 0

    return HealthRowsBuilder.Inputs(
      allowlist: AllowlistHealth(
        seeded: try? stores.allowlist.allowlistCount(),
        configured: config.allowlist.count
      ),
      lastOffset: try? stores.cursor.loadCursor(),
      runsHealth: runsHealth,
      routeHealth: routeHealth,
      retryBudget: config.llm.retryBudget,
      streamingEnabled: config.llm.streamingEnabled,
      todayTokens: todayTokens,
      todayUSD: todayUSD,
      costMix: costMix,
      perDayUSD: config.budget.perDayUSD,
      perRunUSD: config.budget.perRunUSD,
      walBytes: walBytes,
      freeBytes: freeBytes,
      latestContext: latestContext
    )
  }

  static func schedulerChecks(
    stores: ClawStores,
    config: AppConfig,
    now: Date
  ) -> [DoctorReport.Check] {
    let emptyState = SchedulerState(
      lastTickAt: nil,
      lastMisfireAt: nil,
      lastMisfireSkippedCount: 0,
      lastHeartbeatAt: nil,
      heartbeatCountDay: nil,
      heartbeatCount: 0
    )
    let state = (try? stores.scheduledJobs.schedulerState()) ?? emptyState

    let dueCount = try? stores.scheduledJobs.dueJobs(now: now).count
    let proactiveUsage = try? stores.usage.todayTokensAndCost(
      origins: [.scheduled, .heartbeat],
      now: now
    )

    let snapshot = SchedulerHealth.Snapshot(
      state: state,
      dueCount: dueCount,
      proactiveTodayUSD: proactiveUsage?.costUSD,
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
    let emptyHealth = ApprovalsHealth(pendingCount: 0, oldestPendingAgeSeconds: nil)
    let health = (try? stores.approvals.approvalsHealth(now: now)) ?? emptyHealth

    return ApprovalsHealthRows.rows(
      health: health,
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
