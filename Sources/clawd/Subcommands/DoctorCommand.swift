import ArgumentParser
import AsyncHTTPClient
import ClawCore
import ClawData
import ClawGateway
import ClawSecrets
import ClawTelegram
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
      config = try AppConfig.load(environment: ProcessInfo.processInfo.environment)
    } catch let error as ConfigError {
      report.add(key: "config", value: "FAIL: \(error)", ok: false)
      emit(report)
      throw ExitCode(error.exitCode)
    }
    report.add(key: "config", value: "OK")
    report.add(key: "config.max_tokens", value: "\(config.llm.maxOutputTokens)")
    if checkConfig {
      report.add(key: "llm.streaming", value: config.llm.streamingEnabled ? "on" : "off")
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

    do {
      let stores = try ClawDatabase.openStores(
        path: config.stateRoot.appendingPathComponent(StateFile.database).path
      )
      report.add(key: "db.writable", value: "true")

      let owners = (try? stores.allowlist.allowlistCount()) ?? -1
      report.add(key: "allowlist.owners", value: "\(owners)", ok: owners >= 1)

      let offset: Int64? = try? stores.cursor.loadCursor()
      report.add(key: "poller.last_offset", value: offset.map(String.init) ?? "none")

      addHealthRows(to: &report, stores: stores, config: config)
    } catch {
      report.add(key: "db.writable", value: "false: \(error)", ok: false)
    }

    // Best-effort connectivity check (only if a token is available).
    let secretStore = SecretStoreResolver.resolve(
      stateRoot: config.stateRoot,
      environment: ProcessInfo.processInfo.environment
    ).store
    if let secrets = try? secretStore.loadSecrets() {
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

    emit(report)

    if !secretsRow.ok {
      throw ExitCode(ClawExitCode.secretLoadFailed.rawValue)
    }
    if !report.ok {
      throw ExitCode.failure
    }
  }

  private func addHealthRows(
    to report: inout DoctorReport,
    stores: ClawStores,
    config: AppConfig
  ) {
    let now = Date()
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

    let (todayTokens, todayUSD) = (try? stores.usage.todayTokensAndCost(now: now)) ?? (0, 0)
    let mix = (try? stores.usage.costSourceMix(now: now)) ?? [:]
    report.add(key: "spend.today_usd", value: String(format: "%.4f", todayUSD))
    report.add(key: "spend.today_tokens", value: "\(todayTokens)")
    report.add(
      key: "spend.remaining_day_usd",
      value: String(format: "%.2f", max(0, config.budget.perDayUSD - todayUSD))
    )
    report.add(key: "spend.per_run_cap_usd", value: String(format: "%.2f", config.budget.perRunUSD))
    let mixText = mix.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")
    report.add(key: "spend.cost_source_mix", value: mixText.isEmpty ? "none" : mixText)

    let dbPath = config.stateRoot.appendingPathComponent(StateFile.database).path
    let walBytes =
      (try? FileManager.default.attributesOfItem(atPath: dbPath + "-wal")[.size] as? Int) ?? 0
    report.add(key: "db.wal_size", value: "\(walBytes)")

    let fileSystemAttributes = try? FileManager.default.attributesOfFileSystem(
      forPath: config.stateRoot.path
    )
    let freeBytes = (fileSystemAttributes?[.systemFreeSize] as? Int) ?? 0
    report.add(key: "db.free_disk", value: "\(freeBytes)", ok: freeBytes > 0)
  }

  private func emit(_ report: DoctorReport) {
    // swiftlint:disable:next no_print_in_production
    print(json ? report.renderJSON() : report.renderText())
  }
}
