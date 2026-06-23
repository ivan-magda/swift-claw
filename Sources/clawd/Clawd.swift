import ArgumentParser
import AsyncHTTPClient
import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawTelegram
import Foundation
import Logging

@main
struct Clawd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clawd",
    abstract: "swift-claw — single-owner Telegram assistant daemon.",
    subcommands: [Run.self, Doctor.self],
    defaultSubcommand: Run.self
  )
}

/// State-root-relative filenames the daemon owns.
private enum StateFile {
  static let database = "claw.sqlite"
  static let lock = "clawd.lock"
}

struct NoopTypingIndicator: TypingIndicator {
  func sendTyping(chatId: Int64) async {}
}

/// Loads config from the process environment, printing a diagnostic and exiting with the
/// error's distinct code so the supervisor backs off instead of hot-looping.
private func loadConfigOrExit() throws -> AppConfig {
  do {
    return try AppConfig.load(environment: ProcessInfo.processInfo.environment)
  } catch let error as ConfigError {
    FileHandle.standardError.write(Data("config error: \(error)\n".utf8))
    throw ExitCode(error.exitCode)
  }
}

struct Run: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Start the daemon.")

  func run() async throws {
    let logger = Logger(label: "clawd")
    let config = try loadConfigOrExit()

    // Single-instance guard — held until the process exits (defer covers the graceful path).
    let lockPath = config.stateRoot.appendingPathComponent(StateFile.lock).path
    let lock: InstanceLock
    do {
      lock = try InstanceLock(path: lockPath)
    } catch InstanceLock.LockError.alreadyLocked {
      FileHandle.standardError.write(
        Data("another clawd is already running for this state root\n".utf8)
      )
      throw ExitCode(ClawExitCode.alreadyRunning.rawValue)
    }
    defer { lock.release() }

    let stores: ClawStores
    do {
      stores = try ClawDatabase.openStores(
        path: config.stateRoot.appendingPathComponent(StateFile.database).path
      )
    } catch {
      FileHandle.standardError.write(Data("database error: \(error)\n".utf8))
      throw ExitCode(ClawExitCode.storeError.rawValue)
    }
    do {
      // Additive only — removing an ID from config doesn't revoke it. Revocation is deferred
      // to pairing (§17), which needs an audited remove path, not a config-mirroring reconcile.
      try stores.allowlist.seedAllowlist(userIds: Array(config.allowlist))
    } catch {
      logger.error("failed to seed allowlist: \(error)")
    }

    // Shared HTTP client for both Telegram and the LLM; gzip decompression is a client-wide toggle
    // (the executor only advertises `accept-encoding`), so it's configured here at the root.
    var httpConfig = HTTPClient.Configuration()
    httpConfig.decompression = .enabled(limit: .size(16 * 1024 * 1024))
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfig)
    let executor = AsyncHTTPExecutor(client: httpClient)

    let daemon = makeDaemon(config: config, stores: stores, executor: executor, logger: logger)

    logger.info("clawd starting (owners allowlisted: \(config.allowlist.count))")
    var runFailure: Error?
    do {
      try await daemon.run()
    } catch {
      // A graceful shutdown returns without throwing; an error here means a service failed
      // unexpectedly. Re-raise after cleanup so the supervisor restarts the process.
      runFailure = error
      logger.error("daemon exited with error: \(error)")
    }

    try? await httpClient.shutdown()
    if let runFailure {
      throw runFailure
    }
    logger.info("clawd stopped")
  }

  /// Builds the service graph: the OpenAI-compatible provider + agent feed a `TurnRunner`, which
  /// the router dispatches from the poller. Both Telegram and the LLM share the injected executor.
  private func makeDaemon(
    config: AppConfig,
    stores: ClawStores,
    executor: AsyncHTTPExecutor,
    logger: Logger
  ) -> Daemon {
    let transport = TelegramClient(token: config.botToken, http: executor)
    let provider = OpenAICompatibleProvider(
      config: config.llm,
      http: executor,
      sleep: { try await Task.sleep(for: .seconds($0)) },
      jitter: { Double.random(in: 0...$0) }
    )

    let budget = RunBudget.default
    let costResolver = CostResolver(
      priceTable: PriceFileLoader.load(),
      referenceUSDPerToken: budget.referenceUSDPerToken
    )
    let agent = AgentRuntime(
      provider: provider,
      typingIndicator: NoopTypingIndicator(),
      costResolver: costResolver,
      budget: budget,
      model: config.llm.model,
      sleep: { try await Task.sleep(for: $0) }
    )
    let turnRunner = TurnRunner(
      sessionMessages: stores.sessionMessages,
      runs: stores.runs,
      usageStore: stores.usage,
      outbox: stores.outbox,
      audit: stores.audit,
      agent: agent,
      budget: budget,
      systemPrompt: SystemPrompt.minimal,
      notifyOutbox: {},
      logger: logger
    )
    let router = MessageRouter(
      processed: stores.processed,
      sessionMessages: stores.sessionMessages,
      accessControl: AccessControl(allowlist: stores.allowlist),
      transport: transport,
      turnRunner: turnRunner,
      logger: logger
    )
    let poller = TelegramPollerService(
      transport: transport,
      router: router,
      cursor: stores.cursor,
      pollTimeout: config.pollTimeoutSeconds,
      logger: logger
    )
    return Daemon(services: [poller], logger: logger)
  }
}

struct Doctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Run health self-checks.")

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

    if checkConfig {
      emit(report)
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
    } catch {
      report.add(key: "db.writable", value: "false: \(error)", ok: false)
    }

    // Best-effort connectivity check.
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let transport = TelegramClient(
      token: config.botToken,
      http: AsyncHTTPExecutor(client: httpClient)
    )
    if let identity = try? await transport.getMe() {
      report.add(key: "telegram.bot", value: identity.username ?? "id:\(identity.id)")
    } else {
      report.add(key: "telegram.bot", value: "unreachable", ok: false)
    }
    try? await httpClient.shutdown()

    emit(report)
    if !report.ok {
      throw ExitCode.failure
    }
  }

  private func emit(_ report: DoctorReport) {
    // swiftlint:disable:next no_print_in_production
    print(json ? report.renderJSON() : report.renderText())
  }
}
