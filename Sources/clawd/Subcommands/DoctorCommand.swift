import ArgumentParser
import AsyncHTTPClient
import ClawCore
import ClawData
import ClawExec
import ClawGateway
import ClawSecrets
import ClawTelegram
import ClawTools
import Foundation

struct DoctorCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Run health self-checks."
  )

  @Flag(
    name: .customLong("check-config"),
    help: "Validate config/secrets without starting the daemon."
  )
  var checkConfig = false

  @Flag(name: .long, help: "Emit machine-readable JSON.")
  var json = false

  func run() async throws {
    var report = DoctorReport()

    // Config/secret is checked first and printed first if it errored.
    let config: AppConfig
    do {
      config = try EnvironmentLoader.loadConfig()
    } catch let error as ConfigError {
      report.add(key: "config", value: "FAIL: \(error)", ok: false)
      emit(report)
      throw ExitCode(error.exitCode)
    }
    report.add(key: "config", value: "OK")
    report.add(key: "config.max_tokens", value: "\(config.llm.maxOutputTokens)")
    if checkConfig {
      addConfigDetailRows(to: &report, config: config)
      for row in await sandboxRows(config: config, live: false) {
        report.add(key: row.key, value: row.value, ok: row.ok)
      }
    }

    let secretsRow = SecretStoreResolver.doctorRow(
      stateRoot: config.stateRoot,
      environment: ProcessInfo.processInfo.environment
    )
    report.add(key: "secrets", value: secretsRow.value, ok: secretsRow.ok)

    if checkConfig {
      emit(report)

      if !secretsRow.ok {
        throw ExitCode(ClawExitCode.secretLoadFailed.rawValue)
      }
      if !report.ok {
        throw ExitCode(ClawExitCode.configInvalid.rawValue)
      }

      return
    }

    addDatabaseRows(to: &report, config: config)
    await addConnectivityRows(to: &report, config: config)
    for row in await sandboxRows(config: config, live: true) {
      report.add(key: row.key, value: row.value, ok: row.ok)
    }

    emit(report)

    if !secretsRow.ok {
      throw ExitCode(ClawExitCode.secretLoadFailed.rawValue)
    }
    if !report.ok {
      throw ExitCode.failure
    }
  }
}

// MARK: - Check Sections

private extension DoctorCommand {
  func addConfigDetailRows(to report: inout DoctorReport, config: AppConfig) {
    report.add(key: "llm.streaming", value: config.llm.streamingEnabled ? "on" : "off")
    report.add(key: "sched.timezone", value: config.timezone.identifier)
    report.add(key: "sched.catchup_max_age_min", value: "\(config.schedCatchUpMaxAgeMinutes)")
    report.add(key: "sched.min_interval_min", value: "\(config.schedMinIntervalMinutes)")
    // Warn-not-fail: a proactive cap at/above the global cap is legal but inert —
    // the household kill-switch dominates.
    let proactiveNote =
      config.proactivePerDayUSD >= config.budget.perDayUSD
      ? " (>= CLAW_PER_DAY_USD; the global cap dominates)" : ""
    report.add(
      key: "spend.proactive_per_day_usd",
      value: USD.display(config.proactivePerDayUSD) + proactiveNote
    )
    report.add(key: "heartbeat.enabled", value: config.heartbeatEnabled ? "on" : "off")
    report.add(key: "heartbeat.interval_min", value: "\(config.heartbeatIntervalMinutes)")
    report.add(key: "heartbeat.quiet_hours", value: config.heartbeatQuietHours.rendered)
    report.add(key: "heartbeat.max_per_day", value: "\(config.heartbeatMaxPerDay)")
    report.add(key: "approval.expiry_s", value: "\(config.approvalExpirySeconds)")
    let exemptCIDRs = config.webFetchExemptCIDRs.map { cidr in
      "\(cidr)"
    }
    report.add(
      key: "webfetch.exempt_cidrs",
      value: exemptCIDRs.isEmpty ? "none" : exemptCIDRs.joined(separator: " ")
    )
  }

  func addDatabaseRows(to report: inout DoctorReport, config: AppConfig) {
    do {
      let stores = try EnvironmentLoader.openStores(config: config)
      report.add(key: "db.writable", value: "true")

      let owners = (try? stores.allowlist.allowlistCount()) ?? -1
      report.add(key: "allowlist.owners", value: "\(owners)", ok: owners >= 1)

      let offset: Int64? = try? stores.cursor.loadCursor()
      report.add(key: "poller.last_offset", value: offset.map(String.init) ?? "none")

      addHealthRows(to: &report, stores: stores, config: config)
    } catch {
      report.add(key: "db.writable", value: "false: \(error)", ok: false)
    }
  }

  /// Best-effort connectivity check (only if a token is available).
  func addConnectivityRows(to report: inout DoctorReport, config: AppConfig) async {
    // Info, never a failed check: names the fake-IP VPN/proxy condition that otherwise
    // surfaces only as silent web_fetch refusals (needs no secrets, so it precedes the guard).
    switch await FakeIPDetector(resolver: SystemAddressResolver()).detect() {
    case .active(let sample):
      report.add(
        key: "dns.fake_ip",
        value: "detected (public hosts resolve into \(SSRFGuard.benchmarkRange), e.g. \(sample); "
          + "web_fetch allows probe-confirmed answers in that range)"
      )
    case .inactive:
      report.add(key: "dns.fake_ip", value: "not detected")
    }

    guard let secrets = try? EnvironmentLoader.loadSecrets(config: config) else {
      return
    }

    // Info, never a failed check: unconfigured search just means the tool is absent.
    report.add(
      key: "web_search",
      value: secrets.searchApiKey != nil
        ? "configured" : "not configured (web_search tool absent)"
    )

    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let transport = TelegramClient(
      token: secrets.telegramBotToken,
      http: AsyncHTTPExecutor(client: httpClient)
    )

    if let identity = try? await transport.getMe() {
      report.add(key: "telegram.bot", value: identity.username ?? "id:\(identity.id)")
    } else {
      report.add(key: "telegram.bot", value: "unreachable", ok: false)
    }

    try? await httpClient.shutdown()
  }
}

// MARK: - Sandbox Health

private extension DoctorCommand {
  func sandboxRows(
    config: AppConfig,
    live: Bool
  ) async -> [SandboxHealthRows.Row] {
    guard config.exec.enabled else {
      return SandboxHealthRows.rows(for: .disabled)
    }

    #if os(Linux)
      return SandboxHealthRows.rows(for: .linuxDeferred)
    #else
      guard let backend = SandboxBackendFactory.make(config: config, secrets: nil) else {
        return SandboxHealthRows.rows(
          for: .unavailable(reason: "sandbox backend is not configured")
        )
      }

      guard live else {
        let availability = await backend.versionAvailability()
        return SandboxHealthRows.rows(for: .configOnly(availability: availability))
      }

      // A running daemon owns sandbox maintenance (reap + scratch sweep) and holds the
      // single-instance lock for its whole lifetime. Acquiring it here proves no daemon can be
      // mid-execution, so the destructive live canary is safe; failing to acquire it means a daemon
      // is running and doctor must not reap its live VM or sweep its scratch.
      let lockPath = config.stateRoot.appendingPathComponent(StateFile.lock).path
      guard let lock = try? InstanceLock(path: lockPath) else {
        let availability = await backend.versionAvailability()
        return SandboxHealthRows.rows(for: .daemonManaged(availability: availability))
      }
      defer { lock.release() }

      let bootstrap = await SandboxBootstrapper(
        enabled: true,
        backend: backend,
        maintenance: backend
      ).prepare()
      await backend.shutdown()

      if let health = bootstrap.health {
        return SandboxHealthRows.rows(for: .live(health: health))
      }
      return SandboxHealthRows.rows(
        for: .unavailable(
          reason: bootstrap.unavailableReason ?? "sandbox health is unavailable"
        )
      )
    #endif
  }
}

// MARK: - Health Rows

private extension DoctorCommand {
  func addHealthRows(to report: inout DoctorReport, stores: ClawStores, config: AppConfig) {
    let now = Date()
    addRunHealthRows(to: &report, stores: stores, config: config, now: now)
    addSpendRows(to: &report, stores: stores, config: config, now: now)
    addStorageRows(to: &report, config: config)
    addSchedulerRows(to: &report, stores: stores, config: config, now: now)
    addApprovalRows(to: &report, stores: stores, config: config, now: now)
  }

  func addRunHealthRows(
    to report: inout DoctorReport,
    stores: ClawStores,
    config: AppConfig,
    now: Date
  ) {
    let health =
      if let storedRunsHealth = try? stores.runs.runsHealth(now: now) {
        storedRunsHealth
      } else {
        RunsHealth(
          inFlight: 0,
          oldestRunAgeSeconds: nil,
          lastFailedAt: nil,
          lastSuccessAt: nil,
          consecutiveFailures: 0
        )
      }

    report.add(
      key: "llm.last_success",
      value: health.lastSuccessAt.map(String.init(describing:)) ?? "never"
    )
    report.add(key: "llm.consecutive_failures", value: "\(health.consecutiveFailures)")
    report.add(key: "llm.retry_budget", value: "\(config.llm.retryBudget)")
    report.add(key: "llm.streaming", value: config.llm.streamingEnabled ? "on" : "off")
    report.add(key: "runs.in_flight", value: "\(health.inFlight)")
    report.add(
      key: "runs.oldest_age_s",
      value: health.oldestRunAgeSeconds.map { String(format: "%.0f", $0) } ?? "none"
    )
    report.add(
      key: "runs.last_FAILED",
      value: health.lastFailedAt.map(String.init(describing:)) ?? "none"
    )
  }

  func addSpendRows(
    to report: inout DoctorReport,
    stores: ClawStores,
    config: AppConfig,
    now: Date
  ) {
    let (todayTokens, todayUSD) = (try? stores.usage.todayTokensAndCost(now: now)) ?? (0, 0)
    let mix = (try? stores.usage.costSourceMix(now: now)) ?? [:]
    report.add(key: "spend.today_usd", value: USD.precise(todayUSD))
    report.add(key: "spend.today_tokens", value: "\(todayTokens)")
    report.add(
      key: "spend.remaining_day_usd",
      value: USD.display(max(0, config.budget.perDayUSD - todayUSD))
    )
    report.add(key: "spend.per_run_cap_usd", value: USD.display(config.budget.perRunUSD))
    let mixText = mix.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")
    report.add(key: "spend.cost_source_mix", value: mixText.isEmpty ? "none" : mixText)
  }

  func addStorageRows(to report: inout DoctorReport, config: AppConfig) {
    let dbPath = EnvironmentLoader.databasePath(config: config)
    let walBytes =
      (try? FileManager.default.attributesOfItem(atPath: dbPath + "-wal")[.size] as? Int) ?? 0
    report.add(key: "db.wal_size", value: "\(walBytes)")

    let fileSystemAttributes = try? FileManager.default.attributesOfFileSystem(
      forPath: config.stateRoot.path
    )
    let freeBytes = (fileSystemAttributes?[.systemFreeSize] as? Int) ?? 0
    report.add(key: "db.free_disk", value: "\(freeBytes)", ok: freeBytes > 0)
  }

  func addSchedulerRows(
    to report: inout DoctorReport,
    stores: ClawStores,
    config: AppConfig,
    now: Date
  ) {
    let schedulerState =
      (try? stores.scheduledJobs.schedulerState())
      ?? SchedulerState(
        lastTickAt: nil,
        lastMisfireAt: nil,
        lastMisfireSkippedCount: 0,
        lastHeartbeatAt: nil,
        heartbeatCountDay: nil,
        heartbeatCount: 0
      )
    let dueCount = try? stores.scheduledJobs.dueJobs(now: now).count
    let proactiveTodayUSD =
      (try? stores.usage.todayTokensAndCost(origins: [.scheduled, .heartbeat], now: now))?.costUSD
    let snapshot = SchedulerHealth.Snapshot(
      state: schedulerState,
      dueCount: dueCount,
      proactiveTodayUSD: proactiveTodayUSD,
      proactivePerDayUSD: config.budget.proactivePerDayUSD,
      heartbeatEnabled: config.heartbeatEnabled,
      heartbeatMaxPerDay: config.heartbeatMaxPerDay,
      timezone: config.timezone,
      now: now
    )
    for row in SchedulerHealth.rows(snapshot) {
      report.add(key: row.key, value: row.value)
    }
  }

  func addApprovalRows(
    to report: inout DoctorReport,
    stores: ClawStores,
    config: AppConfig,
    now: Date
  ) {
    let approvalsHealth =
      (try? stores.approvals.approvalsHealth(now: now))
      ?? ApprovalsHealth(pendingCount: 0, oldestPendingAgeSeconds: nil)
    for row in ApprovalsHealthRows.rows(
      health: approvalsHealth,
      approvalExpirySeconds: config.approvalExpirySeconds
    ) {
      report.add(key: row.key, value: row.value)
    }
  }
}

// MARK: - Output

private extension DoctorCommand {
  func emit(_ report: DoctorReport) {
    // swiftlint:disable:next no_print_in_production
    print(json ? report.renderJSON() : report.renderText())
  }
}
