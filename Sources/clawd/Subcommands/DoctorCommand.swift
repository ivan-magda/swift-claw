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
      report.add(key: "config", value: "FAIL: \(error)", ok: false, group: .config)
      emit(report)
      throw ExitCode(error.exitCode)
    }
    report.add(key: "config", value: "OK", group: .config)
    report.add(key: "config.max_tokens", value: "\(config.llm.maxOutputTokens)", group: .config)
    if checkConfig {
      addConfigDetailRows(to: &report, config: config)
      report.add(contentsOf: await sandboxRows(config: config, live: false))
    }

    let secretsRow = SecretStoreResolver.doctorRow(
      stateRoot: config.stateRoot,
      environment: ProcessInfo.processInfo.environment
    )
    report.add(key: "secrets", value: secretsRow.value, ok: secretsRow.ok, group: .config)

    addLLMAuthRow(to: &report, config: config)

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
    report.add(contentsOf: await sandboxRows(config: config, live: true))

    emit(report)

    if !json, let hint = serviceStartHint(report: report, config: config) {
      // swiftlint:disable:next no_print_in_production
      print(hint)
    }

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
    report.add(
      key: "llm.streaming",
      value: config.llm.streamingEnabled ? "on" : "off",
      group: .llmRuns
    )
    report.add(key: "sched.timezone", value: config.timezone.identifier, group: .scheduler)
    report.add(
      key: "sched.catchup_max_age_min",
      value: "\(config.schedCatchUpMaxAgeMinutes)",
      group: .scheduler
    )
    report.add(
      key: "sched.min_interval_min",
      value: "\(config.schedMinIntervalMinutes)",
      group: .scheduler
    )
    // Warn-not-fail: a proactive cap at/above the global cap is legal but inert —
    // the household kill-switch dominates.
    let proactiveNote =
      config.proactivePerDayUSD >= config.budget.perDayUSD
      ? " (>= CLAW_PER_DAY_USD; the global cap dominates)" : ""
    report.add(
      key: "spend.proactive_per_day_usd",
      value: USD.display(config.proactivePerDayUSD) + proactiveNote,
      group: .spend
    )
    report.add(
      key: "heartbeat.enabled",
      value: config.heartbeatEnabled ? "on" : "off",
      group: .scheduler
    )
    report.add(
      key: "heartbeat.interval_min",
      value: "\(config.heartbeatIntervalMinutes)",
      group: .scheduler
    )
    report.add(
      key: "heartbeat.quiet_hours",
      value: config.heartbeatQuietHours.rendered,
      group: .scheduler
    )
    report.add(
      key: "heartbeat.max_per_day",
      value: "\(config.heartbeatMaxPerDay)",
      group: .scheduler
    )
    report.add(
      key: "approval.expiry_s",
      value: "\(config.approvalExpirySeconds)",
      group: .approvals
    )
    let exemptCIDRs = config.webFetchExemptCIDRs.map { cidr in
      "\(cidr)"
    }
    report.add(
      key: "webfetch.exempt_cidrs",
      value: exemptCIDRs.isEmpty ? "none" : exemptCIDRs.joined(separator: " "),
      group: .connectivity
    )
  }

  /// The network-free credential-health row. It reads only what is already on disk: the static bearer
  /// already loaded for the current route, or one decrypted ChatGPT record — never a refresh, model
  /// fetch, or entitlement check. The managed store is built only for the ChatGPT route, so the
  /// current API route opens no unused OAuth envelope while the daemon is stopped.
  func addLLMAuthRow(to report: inout DoctorReport, config: AppConfig) {
    // The `secrets` row above owns the decrypt-failure diagnosis and fails loudly there, so an
    // undecryptable store degrades this row quietly to mode=none rather than double-reporting.
    let staticAPIKey = (try? EnvironmentLoader.loadSecrets(config: config))?.llmApiKey
    let result = LLMAuthDoctor.inspect(
      route: config.llm.route,
      staticAPIKey: staticAPIKey,
      now: Date(),
      makeManagedStore: {
        EncryptedLLMCredentialStore(stateRoot: config.stateRoot)
      }
    )
    report.add(key: "llm.auth", value: result.value, ok: result.ok, group: .llmRuns)
  }

  func addDatabaseRows(to report: inout DoctorReport, config: AppConfig) {
    do {
      let stores = try EnvironmentLoader.openStores(config: config)
      report.add(key: "db.writable", value: "true", group: .database)

      addHealthRows(to: &report, stores: stores, config: config)
    } catch {
      report.add(key: "db.writable", value: "false: \(error)", ok: false, group: .database)
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
          + "web_fetch allows probe-confirmed answers in that range)",
        group: .connectivity
      )
    case .inactive:
      report.add(key: "dns.fake_ip", value: "not detected", group: .connectivity)
    }

    guard let secrets = try? EnvironmentLoader.loadSecrets(config: config) else {
      return
    }

    // Info, never a failed check: unconfigured search just means the tool is absent.
    report.add(
      key: "web_search",
      value: secrets.searchApiKey != nil
        ? "configured" : "not configured (web_search tool absent)",
      group: .connectivity
    )

    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let transport = TelegramClient(
      token: secrets.telegramBotToken,
      http: AsyncHTTPExecutor(client: httpClient)
    )

    if let identity = try? await transport.getMe() {
      report.add(
        key: "telegram.bot",
        value: identity.username ?? "id:\(identity.id)",
        group: .connectivity
      )
    } else {
      report.add(key: "telegram.bot", value: "unreachable", ok: false, group: .connectivity)
    }

    try? await httpClient.shutdown()
  }
}

// MARK: - Sandbox Health

private extension DoctorCommand {
  func sandboxRows(
    config: AppConfig,
    live: Bool
  ) async -> [DoctorReport.Check] {
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
    report.add(
      contentsOf: HealthRowsBuilder.checks(
        DoctorHealth.inputs(stores: stores, config: config, now: now)
      )
    )
    report.add(contentsOf: DoctorHealth.schedulerChecks(stores: stores, config: config, now: now))
    report.add(contentsOf: DoctorHealth.approvalChecks(stores: stores, config: config, now: now))
  }
}

// MARK: - Service Hint

private extension DoctorCommand {
  func serviceStartHint(report: DoctorReport, config: AppConfig) -> String? {
    let lockPath = config.stateRoot.appendingPathComponent(StateFile.lock).path
    let daemonRunning: Bool
    if let lock = try? InstanceLock(path: lockPath) {
      lock.release()
      daemonRunning = false
    } else {
      daemonRunning = true
    }
    let failingKeys = report.checks.filter { check in
      !check.ok
    }.map(\.key)
    #if os(Linux)
      let unitPath = NSHomeDirectory() + "/.config/systemd/user/swift-claw.service"
      let isLinux = true
      let serviceManagerAvailable = FileManager.default.fileExists(
        atPath: "/run/systemd/system"
      )
    #else
      let unitPath =
        NSHomeDirectory() + "/Library/LaunchAgents/com.ivanmagda.swift-claw.plist"
      let isLinux = false
      let serviceManagerAvailable = true
    #endif
    return ServiceStartHint.text(
      readiness: .from(reportOK: report.ok, failingKeys: failingKeys),
      daemonRunning: daemonRunning,
      unitInstalled: FileManager.default.fileExists(atPath: unitPath),
      serviceManagerAvailable: serviceManagerAvailable,
      isLinux: isLinux,
      uid: getuid()
    )
  }
}

// MARK: - Output

private extension DoctorCommand {
  func emit(_ report: DoctorReport) {
    // swiftlint:disable:next no_print_in_production
    print(json ? report.renderJSON() : report.renderText())
  }
}
