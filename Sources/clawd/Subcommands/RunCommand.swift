import ArgumentParser
import AsyncHTTPClient
import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawSecrets
import ClawTelegram
import ClawTools
import ClawWorkspace
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

    // Tool fetches get a DEDICATED client with redirects disabled (§7.2/§20-3): AsyncHTTPClient
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
    let botUsername = await fetchBotUsername(transport: transport, logger: logger)

    let daemon = makeDaemon(
      config: config,
      secrets: secrets,
      stores: stores,
      executor: executor,
      toolExecutor: toolExecutor,
      transport: transport,
      botUsername: botUsername,
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
    try? await toolHTTPClient.shutdown()

    if let runFailure {
      throw runFailure
    }
    logger.info("clawd stopped")
  }

  /// Installs the redacting swift-log backend (level from `CLAW_LOG_LEVEL`, default `.info`) over
  /// stdout, then returns the root logger. Bootstrapping here — after secrets load, before the first
  /// `Logger` — hands the redactor the real secret values so no downstream log line can leak them.
  /// The earlier config/secret-load failures stay on stderr and cannot contain these secrets.
  private static func bootstrapLogger(secrets: Secrets) -> Logger {
    let environment = ProcessInfo.processInfo.environment
    let redactor = SecretRedactor(secretValues: secrets.redactionValues)
    DeveloperLogging.bootstrap(
      level: DeveloperLogging.level(from: environment[DeveloperLogging.levelEnvKey]),
      redact: { message in redactor.redact(message) }
    )
    return Logger(label: "clawd")
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
    toolExecutor: AsyncHTTPExecutor,
    transport: TelegramClient,
    botUsername: String?,
    logger: Logger
  ) -> Daemon {
    // Created before the TurnRunner so its notifyOutbox closure can capture it: each commit pokes
    // the dispatcher to drain the rows it just enqueued.
    let outboxSignal = OutboxSignal()
    let breaker = BudgetBreaker(budget: config.budget)
    let lanes = SessionLaneRegistry()
    let pendingConfirmations = PendingConfirmationRegistry()

    let workspace = FileSystemWorkspace(
      root: config.stateRoot.appendingPathComponent("workspace", isDirectory: true)
    )
    let toolDispatcher = makeToolDispatcher(
      secrets: secrets,
      workspace: workspace,
      toolExecutor: toolExecutor
    )
    let agent = makeAgent(
      config: config,
      secrets: secrets,
      executor: executor,
      transport: transport,
      stores: stores,
      toolDispatcher: toolDispatcher,
      logger: logger
    )

    let contextBudget = ContextBudget(
      inputCapGraphemes: TokenEstimator.graphemeBudget(
        forInputTokens: config.budget.maxInputTokens
      ),
      userFileCap: ContextBudget.default.userFileCap,
      memoryFileCap: ContextBudget.default.memoryFileCap,
      itemsCap: ContextBudget.default.itemsCap,
      historyCap: ContextBudget.default.historyCap,
      recallCap: ContextBudget.default.recallCap,
      skillsCap: ContextBudget.default.skillsCap,
      recallHitCap: ContextBudget.default.recallHitCap
    )
    let contextBuilder = ContextBuilder(
      systemPrompt: SystemPrompt.minimal,
      workspace: workspace,
      memoryStore: stores.memory,
      retriever: stores.retriever,
      budget: contextBudget,
      warn: { warning in logger.warning("\(warning)") }
    )

    let turnRunner = TurnRunner(
      sessionMessages: stores.sessionMessages,
      runs: stores.runs,
      usageStore: stores.usage,
      audit: stores.audit,
      agent: agent,
      budget: config.budget,
      contextBuilder: contextBuilder,
      pendingConfirmations: pendingConfirmations,
      notifyOutbox: { outboxSignal.poke() },
      breaker: breaker,
      transport: transport,
      logger: logger
    )
    let router = MessageRouter(
      processed: stores.processed,
      sessionMessages: stores.sessionMessages,
      commands: stores.commands,
      memory: stores.memory,
      memoryCommands: stores.memoryCommands,
      pendingConfirmations: pendingConfirmations,
      botUsername: botUsername,
      accessControl: AccessControl(allowlist: stores.allowlist),
      transport: transport,
      turnRunner: turnRunner,
      lanes: lanes,
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

    let scheduler = SchedulerService(
      jobs: stores.scheduledJobs,
      lanes: lanes,
      turns: turnRunner,
      calculator: OccurrenceCalculator(),
      catchUpMaxAge: .seconds(Int64(config.schedCatchUpMaxAgeMinutes) * 60),
      now: { Date() },
      sleep: { try await Task.sleep(for: $0) },
      logger: logger
    )

    return Daemon(
      services: [poller, dispatcher, scheduler],
      boot: bootSequence(transport: transport, stores: stores, logger: logger),
      logger: logger
    )
  }

  private func fetchBotUsername(transport: TelegramClient, logger: Logger) async -> String? {
    do {
      return try await transport.getMe().username
    } catch {
      logger.warning(
        "failed to fetch bot identity; command mentions will require bare commands: \(error)"
      )
      return nil
    }
  }

  /// Assembles the v1 tool catalog behind its policy gate (§7/§9). Tool fetches use the dedicated
  /// no-redirect `toolExecutor` (§7.2); no `searchApiKey` ⇒ `web_search` is never constructed
  /// (unconfigured ⇒ absent, §7.3). Tier-3 private texts load from DISK at gate-evaluation time
  /// (rev.1 H1), not the assembly snapshot, so the loader closure re-reads the workspace each call.
  private func makeToolDispatcher(
    secrets: Secrets,
    workspace: FileSystemWorkspace,
    toolExecutor: AsyncHTTPExecutor
  ) -> GatedToolDispatcher {
    let secretValues = secrets.redactionValues
    let redactor = SecretRedactor(secretValues: secretValues)

    var tools: [any Tool] = [
      FileReadTool(workspaceRoot: workspace.root, redactor: redactor),
      WebFetchTool(http: toolExecutor, resolver: SystemAddressResolver(), redactor: redactor),
    ]

    if let searchApiKey = secrets.searchApiKey {
      tools.append(
        WebSearchTool(search: ExaSearchProvider(apiKey: searchApiKey, http: toolExecutor))
      )
    }

    let privateFileLoader: @Sendable () -> [String] = {
      [WorkspaceFile.memory, WorkspaceFile.user].compactMap { file in
        try? String(
          contentsOf: workspace.root.appendingPathComponent(file.relativePath),
          encoding: .utf8
        )
      }
    }

    return GatedToolDispatcher(
      registry: ToolRegistry(tools: tools),
      gate: ToolPolicyGate(
        argGuard: ExfilArgGuard(secretValues: secretValues),
        privateFileLoader: privateFileLoader
      )
    )
  }

  /// Assembles the LLM agent stack: the OpenAI-compatible provider, the offline-first cost resolver,
  /// and the `AgentRuntime` that orchestrates one turn. Kept separate from the service wiring so the
  /// composition root reads as "build the agent → feed the turn runner → register the services".
  private func makeAgent(
    config: AppConfig,
    secrets: Secrets,
    executor: AsyncHTTPExecutor,
    transport: TelegramClient,
    stores: ClawStores,
    toolDispatcher: GatedToolDispatcher,
    logger: Logger
  ) -> AgentRuntime {
    let provider = OpenAICompatibleProvider(
      config: config.llm.withAPIKey(secrets.llmApiKey ?? ""),
      http: executor,
      sleep: { try await Task.sleep(for: .seconds($0)) },
      jitter: { Double.random(in: 0...$0) },
      logger: logger
    )

    let costResolver = CostResolver(
      priceTable: PriceFileLoader.load(),
      referenceUSDPerToken: config.budget.referenceUSDPerToken
    )

    return AgentRuntime(
      provider: provider,
      typingIndicator: TelegramTypingIndicator(transport: transport),
      draftStreamer: TelegramRichDraftStreamer(transport: transport),
      streamingEnabled: config.llm.streamingEnabled,
      costResolver: costResolver,
      budget: config.budget,
      model: config.llm.model,
      toolDispatcher: toolDispatcher,
      usageStore: stores.usage,
      auditLog: stores.audit,
      logger: logger,
      sleep: { try await Task.sleep(for: $0) }
    )
  }

  /// Composes the daemon's one-shot boot reconciliation: register the command menu with Telegram,
  /// then sweep crash-orphaned runs (F22). The steps are independent and best-effort, so the order
  /// is cosmetic; both run before any update is served.
  private func bootSequence(
    transport: any TelegramTransport,
    stores: ClawStores,
    logger: Logger
  ) -> @Sendable () async -> Void {
    let registerMenu = registerMenuCommands(transport: transport, logger: logger)
    let reconcileRuns = bootReconcile(stores: stores, logger: logger)
    return {
      await registerMenu()
      await reconcileRuns()
    }
  }

  /// Builds the boot step that registers the command menu with Telegram. This is a reconciliation:
  /// `setMyCommands` writes persistent server-side state, so re-declaring on every boot keeps the
  /// registered picker in sync with this build's `botMenuCommands`. Best-effort — a failure only
  /// means the picker is stale, never that the bot can't serve.
  private func registerMenuCommands(
    transport: any TelegramTransport,
    logger: Logger
  ) -> @Sendable () async -> Void {
    {
      do {
        try await transport.setMyCommands(
          [
            BotMenuCommand(command: "start", description: "Start the bot."),
            BotMenuCommand(command: "new", description: "Start a new session."),
            BotMenuCommand(command: "stop", description: "Stop the current run."),
            BotMenuCommand(command: "remember", description: "Save a memory."),
            BotMenuCommand(command: "memory", description: "Review saved memories."),
          ]
        )
      } catch {
        logger.warning("setMyCommands failed: \(error)")
      }
    }
  }

  /// The boot step that sweeps any run left RUNNING by a crash to FAILED and enqueues a degradation
  /// reply, so a turn interrupted mid-flight is never silent (F22). It runs before the services
  /// serve, so the dispatcher's boot drain delivers whatever this enqueues.
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
