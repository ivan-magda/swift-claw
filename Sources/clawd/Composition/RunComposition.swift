import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawSecrets
import ClawTelegram
import Foundation
import Logging

/// The composition step `RunCommand` runs after config, secrets, stores, and the instance lock are in
/// hand: build the three independent HTTP clients, resolve the route into a provider stack on the
/// dedicated LLM client, and assemble the daemon bundle — closing every already-created client if any
/// of that throws.
///
/// It exists as its own type, with its seams injectable, so a test drives the production selection and
/// cleanup ordering with scripted factories instead of real sockets: which client identity reaches
/// which consumer, that the current route never opens an OAuth envelope, that a missing ChatGPT record
/// still boots, that a malformed one propagates, and that a build failure leaks no client.
struct RunComposition {
  let config: AppConfig
  let secrets: Secrets
  let stores: ClawStores
  let logger: Logger

  /// The MCP catalog and tokens `run` resolved before the logger. Empty means the feature is off,
  /// which is also what a composition test that says nothing about MCP means.
  var mcp: MCPBootInputs = .empty

  /// Builds the three runtime clients. Injectable so a test records which client reaches which
  /// consumer, and counts closes, without opening real sockets.
  var makeClients: @Sendable () -> RuntimeHTTPClients<RuntimeHTTPClient> = {
    RuntimeHTTPClients.live()
  }

  /// Builds the managed credential store from the state root. Injectable so a test scripts a missing
  /// or malformed envelope, and observes whether it is opened at all, without a real encrypted file.
  var makeManagedStore: @Sendable (URL) -> any LLMCredentialStore = { stateRoot in
    EncryptedLLMCredentialStore(stateRoot: stateRoot)
  }

  /// Reads the bot identity for command-mention parsing. Injectable so a composition test never opens
  /// a socket to Telegram. A transient failure is logged with its consequence — mention parsing falls
  /// back to bare commands — so a daemon that boots while Telegram is unreachable does not run its
  /// whole lifetime with degraded `/cmd@bot` handling and no operator signal.
  var fetchBotUsername: @Sendable (TelegramClient, Logger) async -> String? = { transport, logger in
    do {
      return try await transport.getMe().username
    } catch {
      logger.warning(
        "failed to fetch bot identity; command mentions will require bare commands: \(error)"
      )
      return nil
    }
  }

  /// Assembles the daemon bundle from the roster and the shared cooldown. Injectable so a test
  /// forces a post-clients build failure and proves every already-created client is closed rather
  /// than leaked, and so an acceptance test reads the exact roster and cooldown the daemon runs on.
  var buildDaemon:
    @Sendable (DaemonBuilder, RosterStack, RouteCooldown<ContinuousClock>) async throws ->
      DaemonRuntimeBundle = Self.assembleDaemon

  struct Composed {
    let bundle: DaemonRuntimeBundle
    let clients: RuntimeHTTPClients<RuntimeHTTPClient>
  }

  /// Composes the runtime, or throws with every client already closed. The provider stack is built on
  /// the dedicated LLM client, so a malformed managed envelope throws here — after the clients exist —
  /// and the cleanup below closes them before the error propagates to its exit-code mapping.
  func compose() async throws -> Composed {
    let clients = makeClients()
    let transport = TelegramClient(
      token: secrets.telegramBotToken,
      http: clients.telegram.executor,
      downloadHTTP: clients.tool.executor
    )

    do {
      let botUsername = await fetchBotUsername(transport, logger)

      let builder = DaemonBuilder(
        config: config,
        secrets: secrets,
        stores: stores,
        toolExecutor: clients.tool.executor,
        transport: transport,
        botUsername: botUsername,
        mcp: mcp,
        logger: logger,
        makeManagedStore: { makeManagedStore(config.stateRoot) }
      )
      let stack = try builder.makeRosterStack(http: clients.llm.executor)
      // ONE ledger for the whole process. The turn path and the /schedule parse both take this
      // instance, so a window a turn arms is a window the next scheduled parse already sees; two
      // instances would each re-probe a route the other knows is walled off.
      let cooldown = RouteCooldown(
        longSeconds: config.llm.primaryCooldownSeconds,
        clock: ContinuousClock()
      )
      let bundle = try await buildDaemon(builder, stack, cooldown)

      return Composed(bundle: bundle, clients: clients)
    } catch {
      await Self.closeAll(clients, logger: logger)
      throw error
    }
  }
}

// MARK: - Assembly

extension RunComposition {
  /// The production daemon assembly, factored out so the injectable `buildDaemon` default is a plain
  /// function reference rather than a multi-line closure the formatter and linter disagree on.
  static func assembleDaemon(
    _ builder: DaemonBuilder,
    _ stack: RosterStack,
    _ cooldown: RouteCooldown<ContinuousClock>
  ) async throws -> DaemonRuntimeBundle {
    try await builder.build(rosterStack: stack, cooldown: cooldown)
  }
}

// MARK: - Cleanup

extension RunComposition {
  /// Closes all three clients on a failed boot, in the same LLM → Telegram → tool order the clean
  /// shutdown uses. Every client closes even when an earlier close throws: a client left open on a
  /// failed boot is a socket the process would otherwise carry to exit.
  static func closeAll(
    _ clients: RuntimeHTTPClients<RuntimeHTTPClient>,
    logger: Logger
  ) async {
    for client in [clients.llm, clients.telegram, clients.tool] {
      do {
        try await client.close()
      } catch {
        logger.error("client shutdown failed during failed-boot cleanup: \(error)")
      }
    }
  }
}
