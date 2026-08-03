import ArgumentParser
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

    // Single-instance guard — acquired before any credential snapshot and held until process exit.
    let lock = try Self.acquireInstanceLockOrExit(config: config)
    defer { lock.release() }

    let secrets = try Self.loadSecretsOrExit(config: config)
    // Before the logger on purpose: the MCP tokens are part of the redaction set the log backend is
    // installed with, so they have to be in hand before anything can write a line.
    let mcp = try Self.loadMCPOrExit(config: config)
    let redactionValues = mcp.redactionValues(with: secrets)
    let logger = Self.bootstrapLogger(redactionValues: redactionValues)

    let stores = try Self.openStoresOrExit(config: config, logger: logger)
    try Self.ensureWorkspaceDirectoryOrExit(config: config)

    // Three independent clients — Telegram on its redirect-following profile, LLM and tool on the
    // protected redirect-disabled one — plus the route-resolved provider stack and the assembled
    // bundle. A malformed managed credential envelope fails here; the composition closes every client
    // it opened before the error reaches this mapping, and a missing record boots logged out.
    let composed: RunComposition.Composed
    do {
      composed = try await RunComposition(
        config: config,
        secrets: secrets,
        stores: stores,
        logger: logger,
        mcp: mcp
      ).compose()
    } catch let error as LLMCredentialStoreError {
      FileHandle.standardError.write(Data("credential store error: \(error)\n".utf8))
      throw ExitCode(ClawExitCode.secretLoadFailed.rawValue)
    }

    logger.info("clawd starting (owners allowlisted: \(config.allowlist.count))")
    try await Self.serveThenShutDown(
      composed: composed,
      redactionValues: redactionValues,
      logger: logger
    )
  }
}

// MARK: - Serve & Shutdown

private extension RunCommand {
  /// Runs the service graph, then sequences dependent-resource teardown in the mandated order. On a
  /// lane-drain timeout it terminates the process from here — before `run`'s `defer { lock.release()
  /// }` and any client teardown unwind — so the held instance-lock fd stays owned until termination.
  static func serveThenShutDown(
    composed: RunComposition.Composed,
    redactionValues: [String],
    logger: Logger
  ) async throws {
    let bundle = composed.bundle
    let clients = composed.clients

    var runFailure: Error?
    do {
      try await bundle.daemon.run()
    } catch {
      // A graceful shutdown returns without throwing; an error here means a service failed
      // unexpectedly. Re-raise after cleanup so the supervisor restarts the process.
      runFailure = error
      logger.error("daemon exited with error: \(error)")
    }

    // The lane-admission service records its drain result as the service graph shuts down, so a
    // missing record is not a silently-skipped drain: once its run() starts, every path — graceful
    // shutdown OR a sibling-failure cancellation — reaches record, so a live turn can never coexist
    // with a missing record. The record is absent only when run() was never invoked, which happens
    // solely when the ServiceGroup never started its service tasks (a pre-serve boot failure). The
    // poller that admits turns lives in that same group, so if it never ran, nothing was ever
    // enqueued: there is nothing live to drain and `.drained` is the safe default, not fail-open.
    let laneDrain = await bundle.laneShutdownOutcome.value() ?? .drained
    let coordinator = RuntimeShutdownCoordinator(
      logger: logger,
      redactor: SecretRedactor(secretValues: redactionValues)
    )
    let outcome = await coordinator.shutDown(
      daemonError: runFailure,
      laneDrain: laneDrain,
      dependent: RuntimeShutdownCoordinator.DependentCleanup(
        commitCredentials: { try await bundle.credentialSource.shutdown() },
        // The dedicated redirect-disabled LLM client, now its own resource rather than the Telegram
        // client it shared: its transport stays alive across the credential commit above so a
        // refresh's token rotation can finish, then closes here.
        closeLLMClient: { try await clients.llm.close() },
        closeTelegramClient: { try await clients.telegram.close() },
        closeToolClient: { try await clients.tool.close() }
      )
    )

    switch outcome {
    case .clean:
      logger.info("clawd stopped")
    case .failed(let error):
      throw error
    case .fatalLaneTimeout(let activeRunIDs):
      try FatalProcessTerminator.production.fatalLaneDrainTimeout(
        activeRunIDs: activeRunIDs,
        logger: logger
      )
    }
  }
}

// MARK: - Environment Bootstrap

private extension RunCommand {
  /// Installs the redacting swift-log backend (level from `CLAW_LOG_LEVEL`, default `.info`) over
  /// stdout, then returns the root logger. Bootstrapping here — after every secret is loaded, before
  /// the first `Logger` — hands the redactor the whole union so no downstream log line can leak one.
  /// The earlier config/secret-load failures stay on stderr and cannot contain these secrets.
  static func bootstrapLogger(redactionValues: [String]) -> Logger {
    let environment = ProcessInfo.processInfo.environment
    let redactor = SecretRedactor(secretValues: redactionValues)

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
}

// MARK: - MCP Bootstrap

/// Internal rather than file-private so the two refusals below — which decide whether a daemon comes
/// up at all — can be driven by a test with no process to exit.
extension RunCommand {
  /// Loads the MCP catalog and the tokens bound to it. Both failures are the owner's and both are
  /// loud: a malformed catalog exits `configInvalid` like any other bad config, and an unopenable
  /// credential envelope joins `secrets.enc`'s family rather than booting with silent no-auth.
  static func loadMCPOrExit(config: AppConfig) throws -> MCPBootInputs {
    let catalog: MCPConfig
    do {
      catalog = try EnvironmentLoader.loadMCPConfig(config: config)
    } catch let error as MCPConfigError {
      FileHandle.standardError.write(Data("mcp config error: \(error)\n".utf8))
      throw ExitCode(error.exitCode)
    } catch {
      FileHandle.standardError.write(Data("mcp config error: \(error)\n".utf8))
      throw ExitCode(ClawExitCode.configInvalid.rawValue)
    }

    do {
      return MCPBootInputs(
        config: catalog,
        credentials: try EnvironmentLoader.loadMCPCredentials(
          config: config,
          servers: catalog.servers
        )
      )
    } catch {
      FileHandle.standardError.write(Data("mcp credential error: \(error)\n".utf8))
      throw ExitCode(ClawExitCode.secretLoadFailed.rawValue)
    }
  }
}
