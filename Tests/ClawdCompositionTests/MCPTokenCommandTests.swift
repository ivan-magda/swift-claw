import ArgumentParser
import ClawCore
import ClawGateway
import ClawSecrets
import ClawTestSupport
import Foundation
import Testing

@testable import clawd

/// `clawd mcp set-token` / `clear-token` write the same state root the daemon boots from, so both
/// hold its single-instance lock: the daemon reads MCP credentials once at boot, and a token
/// rewritten under a running daemon would be a change nothing picks up.
@Suite struct MCPTokenCommandTests {
  // MARK: - set-token

  @Test func setTokenBindsTheTokenToTheConfiguredServerURL() throws {
    // given
    let stateRoot = try makeTokenStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let context = try makeContext(stateRoot: stateRoot)

    // when
    let outcome = try MCPCommand.setToken("mcp-token", server: "linear", context: context)

    // then
    #expect(outcome == .stored(server: "linear"))
    let stored = try EncryptedMCPCredentialStore(stateRoot: stateRoot).load(
      server: try makeServer()
    )
    #expect(stored == .token("mcp-token"))
  }

  @Test func setTokenRefusesAServerTheConfigDoesNotDeclareAndStoresNothing() throws {
    // given — the URL a token is bound to comes from the config, so a name that is not there is a
    // token nothing could ever be allowed to send.
    let stateRoot = try makeTokenStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let context = try makeContext(stateRoot: stateRoot)

    // when
    let thrown = #expect(throws: ExitCode.self) {
      try MCPCommand.setToken("mcp-token", server: "typo", context: context)
    }

    // then
    #expect(thrown == ExitCode(ClawExitCode.configInvalid.rawValue))
    #expect(FileManager.default.fileExists(atPath: envelopePath(in: stateRoot)) == false)
  }

  @Test func setTokenRefusesWhileTheInstanceLockIsHeldAndStoresNothing() throws {
    // given — a running daemon (or another mutating command) owns the state root.
    let stateRoot = try makeTokenStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let context = try makeContext(stateRoot: stateRoot)
    let heldLock = try InstanceLock(
      path: SecretStatePaths(stateRoot: stateRoot).instanceLock.path
    )
    defer { heldLock.release() }

    // when
    let thrown = #expect(throws: ExitCode.self) {
      try MCPCommand.setToken("mcp-token", server: "linear", context: context)
    }

    // then — the daemon's own already-running code, so a supervisor treats it as non-retryable.
    #expect(thrown == ExitCode(ClawExitCode.alreadyRunning.rawValue))
    #expect(FileManager.default.fileExists(atPath: envelopePath(in: stateRoot)) == false)
  }

  @Test func setTokenReleasesTheLockSoASecondVerbCanRun() throws {
    // given
    let stateRoot = try makeTokenStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let context = try makeContext(stateRoot: stateRoot)

    // when
    _ = try MCPCommand.setToken("mcp-token", server: "linear", context: context)

    // then — a lease that outlived its verb would lock the owner out of their own state root.
    #expect(
      try MCPCommand.clearToken(server: "linear", stateRoot: stateRoot)
        == .cleared(server: "linear")
    )
  }

  @Test func setTokenAgainRepairsAServerThatWasRePointed() throws {
    // given — a token issued for the old host, and a config now naming a new one.
    let stateRoot = try makeTokenStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let old = try makeContext(stateRoot: stateRoot, url: "https://old.example/mcp")
    _ = try MCPCommand.setToken("old-host-token", server: "linear", context: old)
    let repointed = try makeServer(url: "https://new.example/mcp")
    let store = EncryptedMCPCredentialStore(stateRoot: stateRoot)
    #expect(try store.load(server: repointed) == .boundToDifferentURL)

    // when
    _ = try MCPCommand.setToken(
      "new-host-token",
      server: "linear",
      context: try makeContext(stateRoot: stateRoot, url: "https://new.example/mcp")
    )

    // then
    #expect(try store.load(server: repointed) == .token("new-host-token"))
  }

  // MARK: - clear-token

  @Test func clearTokenRemovesAStoredTokenAndSaysSoOnlyOnce() throws {
    // given
    let stateRoot = try makeTokenStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    _ = try MCPCommand.setToken(
      "mcp-token",
      server: "linear",
      context: try makeContext(stateRoot: stateRoot)
    )

    // when
    let cleared = try MCPCommand.clearToken(server: "linear", stateRoot: stateRoot)
    let again = try MCPCommand.clearToken(server: "linear", stateRoot: stateRoot)

    // then — clearing what is already gone is the state the owner asked for, not a failure.
    #expect(cleared == .cleared(server: "linear"))
    #expect(again == .nothingToClear(server: "linear"))
    #expect(
      try EncryptedMCPCredentialStore(stateRoot: stateRoot).load(server: try makeServer())
        == .absent
    )
  }

  @Test func clearTokenNeedsNoConfigSoARetiredServersTokenCanStillBeRemoved() throws {
    // given — the server has been deleted from `mcp.yaml`, leaving its token behind.
    let stateRoot = try makeTokenStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedMCPCredentialStore(stateRoot: stateRoot).save(
      token: "retired-token",
      for: try makeServer(name: "retired", url: "https://retired.example/mcp")
    )

    // when / then
    #expect(
      try MCPCommand.clearToken(server: "retired", stateRoot: stateRoot)
        == .cleared(server: "retired")
    )
  }

  @Test func clearTokenRefusesWhileTheInstanceLockIsHeldAndRemovesNothing() throws {
    // given
    let stateRoot = try makeTokenStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    _ = try MCPCommand.setToken(
      "mcp-token",
      server: "linear",
      context: try makeContext(stateRoot: stateRoot)
    )
    let heldLock = try InstanceLock(
      path: SecretStatePaths(stateRoot: stateRoot).instanceLock.path
    )
    defer { heldLock.release() }

    // when
    let thrown = #expect(throws: ExitCode.self) {
      try MCPCommand.clearToken(server: "linear", stateRoot: stateRoot)
    }

    // then
    #expect(thrown == ExitCode(ClawExitCode.alreadyRunning.rawValue))
    #expect(
      try EncryptedMCPCredentialStore(stateRoot: stateRoot).load(server: try makeServer())
        == .token("mcp-token")
    )
  }
}

// MARK: - Fixtures

private extension MCPTokenCommandTests {
  /// A state root as `secrets seal` leaves it: the runtime key exists, so the token map has
  /// something to seal under.
  func makeTokenStateRoot() throws -> URL {
    let stateRoot = try makeTemporaryRoot(prefix: "claw-mcp-token")
    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
      stateRoot: stateRoot
    )
    return stateRoot
  }

  func makeServer(
    name: String = "linear",
    url: String = "https://mcp.example/mcp"
  ) throws -> MCPServerConfig {
    try MCPServerConfig(name: name, url: url)
  }

  func makeContext(
    stateRoot: URL,
    url: String = "https://mcp.example/mcp"
  ) throws -> MCPCommandContext {
    MCPCommandContext(
      stateRoot: stateRoot,
      config: try MCPConfig(servers: [try makeServer(url: url)])
    )
  }

  func envelopePath(in stateRoot: URL) -> String {
    SecretStatePaths(stateRoot: stateRoot).mcpCredentialEnvelope.path
  }
}
