import ArgumentParser
import AsyncHTTPClient
import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawSecrets
import ClawTelegram
import Foundation
import Logging

struct RunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Start the daemon."
  )

  func run() async throws {
    let logger = Logger(label: "clawd")
    let config = try Self.loadConfigOrExit()
    let secrets = try Self.loadSecretsOrExit(config: config)

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

    let daemon = makeDaemon(
      config: config,
      secrets: secrets,
      stores: stores,
      executor: executor,
      logger: logger
    )

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

  /// Loads config from the process environment, printing a diagnostic and exiting with the
  /// error's distinct code so the supervisor backs off instead of hot-looping.
  private static func loadConfigOrExit() throws -> AppConfig {
    do {
      return try AppConfig.load(environment: ProcessInfo.processInfo.environment)
    } catch let error as ConfigError {
      FileHandle.standardError.write(Data("config error: \(error)\n".utf8))
      throw ExitCode(error.exitCode)
    }
  }

  /// Loads secrets via the fail-closed resolver; a secret-load failure exits 11 (non-retryable).
  private static func loadSecretsOrExit(config: AppConfig) throws -> Secrets {
    let resolution = SecretStoreResolver.resolve(
      stateRoot: config.stateRoot,
      environment: ProcessInfo.processInfo.environment
    )
    do {
      return try resolution.store.loadSecrets()
    } catch let error as SecretStoreError {
      FileHandle.standardError.write(Data("secret error: \(error)\n".utf8))
      throw ExitCode(error.exitCode)
    }
  }

  /// Builds the service graph: the OpenAI-compatible provider + agent feed a `TurnRunner`, which
  /// the router dispatches from the poller. Both Telegram and the LLM share the injected executor.
  private func makeDaemon(
    config: AppConfig,
    secrets: Secrets,
    stores: ClawStores,
    executor: AsyncHTTPExecutor,
    logger: Logger
  ) -> Daemon {
    let transport = TelegramClient(token: secrets.telegramBotToken, http: executor)
    let agent = makeAgent(
      config: config,
      secrets: secrets,
      executor: executor,
      transport: transport
    )
    // Created before the TurnRunner so its notifyOutbox closure can capture it: each commit pokes
    // the dispatcher to drain the rows it just enqueued.
    let outboxSignal = OutboxSignal()
    let breaker = BudgetBreaker(budget: config.budget)
    let turnRunner = TurnRunner(
      sessionMessages: stores.sessionMessages,
      runs: stores.runs,
      usageStore: stores.usage,
      outbox: stores.outbox,
      audit: stores.audit,
      agent: agent,
      budget: config.budget,
      systemPrompt: SystemPrompt.minimal,
      notifyOutbox: { outboxSignal.poke() },
      breaker: breaker,
      transport: transport,
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
    let dispatcher = OutboxDispatcher(
      outbox: stores.outbox,
      transport: transport,
      signal: outboxSignal,
      logger: logger
    )
    return Daemon(
      services: [poller, dispatcher],
      bootReconcile: bootReconcile(stores: stores, logger: logger),
      logger: logger
    )
  }

  /// Assembles the LLM agent stack: the OpenAI-compatible provider, the offline-first cost resolver,
  /// and the `AgentRuntime` that orchestrates one turn. Kept separate from the service wiring so the
  /// composition root reads as "build the agent → feed the turn runner → register the services".
  private func makeAgent(
    config: AppConfig,
    secrets: Secrets,
    executor: AsyncHTTPExecutor,
    transport: TelegramClient
  ) -> AgentRuntime {
    let provider = OpenAICompatibleProvider(
      config: config.llm.withAPIKey(secrets.llmApiKey ?? ""),
      http: executor,
      sleep: { try await Task.sleep(for: .seconds($0)) },
      jitter: { Double.random(in: 0...$0) }
    )
    let costResolver = CostResolver(
      priceTable: PriceFileLoader.load(),
      referenceUSDPerToken: config.budget.referenceUSDPerToken
    )
    return AgentRuntime(
      provider: provider,
      typingIndicator: TelegramTypingIndicator(transport: transport),
      costResolver: costResolver,
      budget: config.budget,
      model: config.llm.model,
      sleep: { try await Task.sleep(for: $0) }
    )
  }

  /// The one-shot boot hook: sweep any run left RUNNING by a crash to FAILED and enqueue a
  /// degradation reply, so a turn interrupted mid-flight is never silent (F22). It runs before the
  /// services serve, so the dispatcher's boot drain delivers whatever this enqueues.
  private func bootReconcile(
    stores: ClawStores,
    logger: Logger
  ) -> @Sendable () async -> Void {
    {
      do {
        let replies = try stores.runs.reconcileRunsAtBoot(
          now: Date(),
          degradationText: Degradation.unfinished
        )
        if !replies.isEmpty {
          logger.warning(
            "boot reconcile: \(replies.count) unfinished run(s) → degradation enqueued"
          )
        }
      } catch {
        logger.error("boot reconcile failed: \(error)")
      }
    }
  }
}
