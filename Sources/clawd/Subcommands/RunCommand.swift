import ArgumentParser
import AsyncHTTPClient
import ClawCore
import ClawData
import ClawGateway
import ClawTelegram
import ClawTools
import Foundation
import Logging

struct RunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Start the daemon."
  )

  func run() async throws {
    let config = try Self.loadConfigOrExit()
    let secrets = try Self.loadSecretsOrExit(config: config)
    let logger = Self.bootstrapLogger(secrets: secrets)

    // Single-instance guard — held until the process exits (defer covers the graceful path).
    let lock = try Self.acquireInstanceLockOrExit(config: config)
    defer { lock.release() }

    let stores = try Self.openStoresOrExit(config: config, logger: logger)
    try Self.ensureWorkspaceDirectoryOrExit(config: config)

    // Shared HTTP client for both Telegram and the LLM; gzip decompression is a client-wide toggle
    // (the executor only advertises `accept-encoding`), so it's configured here at the root.
    var httpConfig = HTTPClient.Configuration()
    httpConfig.decompression = .enabled(limit: .size(16 * 1024 * 1024))
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfig)
    let executor = AsyncHTTPExecutor(client: httpClient)

    // Tool fetches get a DEDICATED client with redirects disabled: AsyncHTTPClient
    // configures redirect behavior per client, and the Telegram/LLM client must keep its defaults.
    var toolHTTPConfig = HTTPClient.Configuration()
    toolHTTPConfig.redirectConfiguration = .disallow
    toolHTTPConfig.decompression = .enabled(limit: .size(16 * 1024 * 1024))
    let toolHTTPClient = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: toolHTTPConfig
    )
    let toolExecutor = AsyncHTTPExecutor(client: toolHTTPClient)

    let transport = TelegramClient(token: secrets.telegramBotToken, http: executor)
    let botUsername = await Self.fetchBotUsername(transport: transport, logger: logger)

    let daemon = await DaemonBuilder(
      config: config,
      secrets: secrets,
      stores: stores,
      executor: executor,
      toolExecutor: toolExecutor,
      transport: transport,
      botUsername: botUsername,
      logger: logger
    ).build()

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
    try? await toolHTTPClient.shutdown()

    if let runFailure {
      throw runFailure
    }
    logger.info("clawd stopped")
  }
}

// MARK: - Environment Bootstrap

private extension RunCommand {
  /// Installs the redacting swift-log backend (level from `CLAW_LOG_LEVEL`, default `.info`) over
  /// stdout, then returns the root logger. Bootstrapping here — after secrets load, before the first
  /// `Logger` — hands the redactor the real secret values so no downstream log line can leak them.
  /// The earlier config/secret-load failures stay on stderr and cannot contain these secrets.
  static func bootstrapLogger(secrets: Secrets) -> Logger {
    let environment = ProcessInfo.processInfo.environment
    let redactor = SecretRedactor(secretValues: secrets.redactionValues)

    DeveloperLogging.bootstrap(
      level: DeveloperLogging.level(from: environment[DeveloperLogging.levelEnvKey]),
      redact: { redactor.redact($0) }
    )

    return Logger(label: "clawd")
  }

  /// Loads config from the process environment, printing a diagnostic and exiting with the
  /// error's distinct code so the supervisor backs off instead of hot-looping.
  static func loadConfigOrExit() throws -> AppConfig {
    do {
      return try EnvironmentLoader.loadConfig()
    } catch let error as ConfigError {
      FileHandle.standardError.write(Data("config error: \(error)\n".utf8))
      throw ExitCode(error.exitCode)
    }
  }

  /// Loads secrets via the fail-closed resolver; a secret-load failure exits 11 (non-retryable).
  static func loadSecretsOrExit(config: AppConfig) throws -> Secrets {
    do {
      return try EnvironmentLoader.loadSecrets(config: config)
    } catch let error as SecretStoreError {
      FileHandle.standardError.write(Data("secret error: \(error)\n".utf8))
      throw ExitCode(error.exitCode)
    }
  }

  /// Takes the single-instance lock; a second daemon on the same state root exits with the
  /// distinct already-running code instead of corrupting shared state.
  static func acquireInstanceLockOrExit(config: AppConfig) throws -> InstanceLock {
    let lockPath = config.stateRoot.appendingPathComponent(StateFile.lock).path
    do {
      return try InstanceLock(path: lockPath)
    } catch InstanceLock.LockError.alreadyLocked {
      FileHandle.standardError.write(
        Data("another clawd is already running for this state root\n".utf8)
      )
      throw ExitCode(ClawExitCode.alreadyRunning.rawValue)
    }
  }

  static func ensureWorkspaceDirectoryOrExit(config: AppConfig) throws {
    do {
      try EnvironmentLoader.ensureWorkspaceDirectory(config: config)
    } catch {
      FileHandle.standardError.write(Data("workspace error: \(error)\n".utf8))
      throw ExitCode(ClawExitCode.configInvalid.rawValue)
    }
  }

  /// Opens the store bundle and seeds the configured owners, exiting with the store code if the
  /// open fails or if seeding configured owners fails.
  static func openStoresOrExit(config: AppConfig, logger: Logger) throws -> ClawStores {
    let stores: ClawStores
    do {
      stores = try EnvironmentLoader.openStores(config: config)
    } catch {
      FileHandle.standardError.write(Data("database error: \(error)\n".utf8))
      throw ExitCode(ClawExitCode.storeError.rawValue)
    }

    switch AllowlistSeeding.seed(into: stores.allowlist, owners: config.allowlist) {
    case .seeded:
      break
    case .toleratedFailure(let error):
      logger.error("failed to seed allowlist: \(error)")
    case .strandedOwners(let error):
      FileHandle.standardError.write(Data("allowlist seed failed: \(error)\n".utf8))
      throw ExitCode(ClawExitCode.storeError.rawValue)
    }

    return stores
  }

  static func fetchBotUsername(transport: TelegramClient, logger: Logger) async -> String? {
    do {
      return try await transport.getMe().username
    } catch {
      logger.warning(
        "failed to fetch bot identity; command mentions will require bare commands: \(error)"
      )
      return nil
    }
  }
}
