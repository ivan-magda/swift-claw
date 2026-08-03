import ArgumentParser
import ClawCore
import ClawMCP
import ClawSecrets
import ClawTestSupport
import Foundation
import Logging
import Testing

@testable import clawd

/// The two MCP inputs `clawd run` reads before it has a logger, and the exits it takes when either
/// is unusable. Neither may be tolerated into a boot: a catalog the owner mistyped is an ordinary
/// config error, and an envelope that will not open would otherwise put a daemon on the wire talking
/// to configured servers with no credential at all.
@Suite struct MCPBootFailureTests {
  @Test func aMalformedCatalogRefusesTheBootWithTheConfigExit() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-mcp-boot")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try write("servers:\n  - name: linear\n    url: not-a-url\n", to: stateRoot)

    // when
    let thrown = #expect(throws: ExitCode.self) {
      try RunCommand.loadMCPOrExit(config: try config(stateRoot: stateRoot))
    }

    // then
    #expect(thrown == ExitCode(ClawExitCode.configInvalid.rawValue))
  }

  @Test func anUnopenableTokenEnvelopeRefusesTheBootRatherThanBootingUnauthenticated() throws {
    // given a valid catalog and a credential envelope that is not one
    let stateRoot = try makeTemporaryRoot(prefix: "claw-mcp-boot")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
      stateRoot: stateRoot
    )
    try write("servers:\n  - name: linear\n    url: https://mcp.test.invalid/mcp\n", to: stateRoot)
    try Data("not an envelope".utf8).write(
      to: SecretStatePaths(stateRoot: stateRoot).mcpCredentialEnvelope
    )

    // when
    let thrown = #expect(throws: ExitCode.self) {
      try RunCommand.loadMCPOrExit(config: try config(stateRoot: stateRoot))
    }

    // then — the same exit an unreadable `secrets.enc` takes, so a supervisor does not hot-loop.
    #expect(thrown == ExitCode(ClawExitCode.secretLoadFailed.rawValue))
  }

  @Test func noCatalogAtAllIsNotAFailure() throws {
    // given a state root with no mcp.yaml in it
    let stateRoot = try makeTemporaryRoot(prefix: "claw-mcp-boot")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    let inputs = try RunCommand.loadMCPOrExit(config: try config(stateRoot: stateRoot))

    // then
    #expect(inputs.config.servers.isEmpty)
  }

  @Test func corruptOrphanedTokenEnvelopeStillRefusesTheBoot() throws {
    // given no catalog, but a stale credential envelope whose integrity cannot be trusted
    let stateRoot = try makeTemporaryRoot(prefix: "claw-mcp-boot")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
      stateRoot: stateRoot
    )
    try Data("not an envelope".utf8).write(
      to: SecretStatePaths(stateRoot: stateRoot).mcpCredentialEnvelope
    )

    // when
    let thrown = #expect(throws: ExitCode.self) {
      try RunCommand.loadMCPOrExit(config: try config(stateRoot: stateRoot))
    }

    // then
    #expect(thrown == ExitCode(ClawExitCode.secretLoadFailed.rawValue))
  }
}

/// Sessions opened at boot outlive the tools that use them — a server may contribute none at all —
/// so hanging up is the service graph's job rather than any adapter's.
@Suite struct MCPSessionLifecycleServiceTests {
  @Test func shutdownHangsUpEverySessionEvenOnesNoToolHolds() async throws {
    // given two live sessions against a server that advertises nothing, so no `MCPTool` retains
    // either one
    let scripted = ScriptedMCPHTTPServer(tools: [])
    let sessions = try ["linear", "notion"].map { name in
      MCPSessionFactory.make(
        server: try MCPServerConfig(name: name, url: "https://\(name).test.invalid/mcp"),
        token: nil,
        http: scripted,
        logger: Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })
      )
    }
    for session in sessions {
      try await session.connect()
    }

    // when the service ends, as it does on graceful shutdown
    try await MCPSessionLifecycleService(
      sessions: sessions,
      clock: ScriptedClock { duration in
        #expect(duration == MCPSessionLifecycleService.idleInterval)
        await Task.yield()
        throw CancellationError()
      }
    ).run()

    // then both sessions were handed back rather than stranded on the server until it expires them
    #expect(await scripted.teardowns == 2)
  }
}

// MARK: - Fixtures

private extension MCPBootFailureTests {
  func config(stateRoot: URL) throws -> AppConfig {
    try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: stateRoot.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
    ])
  }

  func write(_ yaml: String, to stateRoot: URL) throws {
    try Data(yaml.utf8).write(to: stateRoot.appendingPathComponent("mcp.yaml"))
  }
}
