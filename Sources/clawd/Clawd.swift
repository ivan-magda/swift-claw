import ArgumentParser
import AsyncHTTPClient
import ClawCore
import ClawData
import ClawGateway
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

    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let transport = TelegramClient(
      token: config.botToken,
      http: AsyncHTTPExecutor(client: httpClient)
    )

    let daemon = Daemon(
      transport: transport,
      processed: stores.processed,
      allowlist: stores.allowlist,
      cursor: stores.cursor,
      pollTimeout: config.pollTimeoutSeconds,
      logger: logger
    )

    logger.info("clawd starting (owners allowlisted: \(config.allowlist.count))")
    var runFailure: Error?
    do {
      try await daemon.run()
    } catch {
      // A graceful shutdown returns without throwing; a thrown error means a service failed
      // unexpectedly. Re-raise it after cleanup so the process exits non-zero and the
      // supervisor restarts us (a clean stop still returns 0).
      runFailure = error
      logger.error("daemon exited with error: \(error)")
    }

    try? await httpClient.shutdown()
    if let runFailure {
      throw runFailure
    }
    logger.info("clawd stopped")
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
      token: config.botToken, http: AsyncHTTPExecutor(client: httpClient)
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
    print(json ? report.renderJSON() : report.renderText())
  }
}
