import ClawCore
import ClawData
import ClawExec
import ClawGateway
import ClawWorkspace
import Foundation

enum DoctorHealth {
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

    return HealthRowsBuilder.Inputs(
      allowlist: AllowlistHealth(
        seeded: try? stores.allowlist.allowlistCount(),
        configured: config.allowlist.count
      ),
      lastOffset: try? stores.cursor.loadCursor(),
      runsHealth: read { try stores.runs.runsHealth(now: now) },
      routeHealth: routeHealth,
      retryBudget: config.llm.retryBudget,
      streamingEnabled: config.llm.streamingEnabled,
      todayUsage: read { try stores.usage.todayTokensAndCost(now: now) },
      costMix: read { try stores.usage.costSourceMix(now: now) },
      perDayUSD: config.budget.perDayUSD,
      perRunUSD: config.budget.perRunUSD,
      walBytes: walBytes,
      freeBytes: freeBytes,
      latestContext: read { try stores.usage.latestPromptUsage() },
      skillDiagnostics: skillDiagnostics
    )
  }

  static func skillScan(config: AppConfig) -> SkillScanResult {
    FileSystemWorkspace(root: EnvironmentLoader.workspaceRoot(config: config)).scanSkills()
  }

  static func schedulerChecks(
    stores: ClawStores,
    config: AppConfig,
    now: Date
  ) -> [DoctorReport.Check] {
    let snapshot = SchedulerHealth.Snapshot(
      state: read { try stores.scheduledJobs.schedulerState() },
      dueCount: read { try stores.scheduledJobs.dueJobs(now: now).count },
      proactiveTodayUSD: read {
        try stores.usage.todayTokensAndCost(
          origins: [.scheduled, .heartbeat],
          now: now
        ).costUSD
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
      health: read { try stores.approvals.approvalsHealth(now: now) },
      approvalExpirySeconds: config.approvalExpirySeconds
    )
  }

  static func bashChecks(config: AppConfig) -> [DoctorReport.Check] {
    BashHealthRows.rows(for: .resolve(config: config.bash))
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

private extension DoctorHealth {
  static func read<Value: Sendable>(
    _ load: () throws -> Value
  ) -> HealthValue<Value> {
    do {
      return .available(try load())
    } catch {
      return .unavailable
    }
  }
}
