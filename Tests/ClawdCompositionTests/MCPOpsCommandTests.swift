import ArgumentParser
import ClawCore
import ClawGateway
import ClawMCP
import ClawSecrets
import ClawTestSupport
import Foundation
import Logging
import Testing

@testable import clawd

/// `clawd mcp list` — the static half of the ops surface. It contacts nothing, so it answers the
/// same way whether the daemon is up, down, or every server is unreachable.
@Suite struct MCPListCommandTests {
  @Test func listReportsEachServerWithItsTokenStateAndEffectiveFilter() throws {
    // given — one server carrying a token, one filtered and holding none
    let stateRoot = try makeSealedStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let linear = try MCPServerConfig(name: "linear", url: "https://linear.test.invalid/mcp")
    let notion = try MCPServerConfig(
      name: "notion",
      url: "https://notion.test.invalid/mcp",
      tools: MCPToolFilter(include: ["search"])
    )
    try EncryptedMCPCredentialStore(stateRoot: stateRoot).save(token: "linear-token", for: linear)
    let context = MCPCommandContext(
      stateRoot: stateRoot,
      config: try MCPConfig(servers: [linear, notion])
    )

    // when
    let report = try MCPCommand.listReport(context: context)

    // then
    #expect(report.ok)
    let rows = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.key, $0.value) })
    #expect(rows["mcp"] == "2 configured, 2 enabled")
    #expect(try #require(rows["mcp.linear"]).contains("token set"))
    #expect(try #require(rows["mcp.linear"]).contains("all tools"))
    #expect(try #require(rows["mcp.notion"]).contains("no token"))
    #expect(try #require(rows["mcp.notion"]).contains("include: search"))
  }

  @Test func listNeverPrintsTheTokenItReportsOn() throws {
    // given
    let stateRoot = try makeSealedStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let linear = try MCPServerConfig(name: "linear", url: "https://linear.test.invalid/mcp")
    try EncryptedMCPCredentialStore(stateRoot: stateRoot).save(token: "linear-token", for: linear)

    // when
    let report = try MCPCommand.listReport(
      context: MCPCommandContext(stateRoot: stateRoot, config: try MCPConfig(servers: [linear]))
    )

    // then — the verb runs before any redacting log backend exists, so it must be safe by itself
    #expect(report.renderText().contains("linear-token") == false)
  }

  @Test func listFailsTheRowForATokenBoundToAnotherURL() throws {
    // given — the server was re-pointed after its token was issued
    let stateRoot = try makeSealedStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedMCPCredentialStore(stateRoot: stateRoot).save(
      token: "old-host-token",
      for: try MCPServerConfig(name: "linear", url: "https://old.test.invalid/mcp")
    )
    let repointed = try MCPServerConfig(name: "linear", url: "https://new.test.invalid/mcp")

    // when
    let report = try MCPCommand.listReport(
      context: MCPCommandContext(stateRoot: stateRoot, config: try MCPConfig(servers: [repointed]))
    )

    // then — only the owner can repair it, so it has to read as a failure
    #expect(report.ok == false)
    let row = try #require(report.checks.first { $0.key == "mcp.linear" })
    #expect(row.value.contains("clawd mcp set-token"))
  }

  @Test func listNamesATokenLeftBehindByAServerTheConfigNoLongerDeclares() throws {
    // given — the server was deleted from the catalog, leaving its record behind
    let stateRoot = try makeSealedStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    try EncryptedMCPCredentialStore(stateRoot: stateRoot).save(
      token: "retired-token",
      for: try MCPServerConfig(name: "retired", url: "https://retired.test.invalid/mcp")
    )
    let linear = try MCPServerConfig(name: "linear", url: "https://linear.test.invalid/mcp")

    // when
    let report = try MCPCommand.listReport(
      context: MCPCommandContext(stateRoot: stateRoot, config: try MCPConfig(servers: [linear]))
    )

    // then — nothing can send it, so it is a cleanup hint rather than a failure
    let row = try #require(report.checks.first { $0.key == "mcp.unbound_tokens" })
    #expect(row.ok)
    #expect(row.value.contains("retired"))
    #expect(row.value.contains("clear-token"))
    #expect(report.ok)
  }

  @Test func listOnAnEmptyCatalogSaysSoRatherThanPrintingNothing() throws {
    // given
    let stateRoot = try makeSealedStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    let report = try MCPCommand.listReport(
      context: MCPCommandContext(stateRoot: stateRoot, config: .empty)
    )

    // then
    #expect(report.checks.map(\.key) == ["mcp"])
    #expect(report.checks[0].value == "no servers configured")
  }
}

/// `clawd mcp probe` — the live half. It runs the same transport, session, and discovery path the
/// daemon takes at boot, so a server that probes clean is a server that will load.
@Suite struct MCPProbeCommandTests {
  // MARK: - Target selection

  @Test func probeWithNoNameTakesEveryEnabledServer() throws {
    // given
    let config = try MCPConfig(servers: [
      try server(named: "linear"),
      try server(named: "notion", enabled: false),
    ])

    // when
    let targets = try MCPCommand.probeTargets(named: nil, config: config)

    // then
    #expect(targets.map(\.name) == ["linear"])
  }

  @Test func probeContactsANamedServerEvenWhenItIsDisabled() throws {
    // given — the owner asked about that one, which is the whole reason to name it
    let config = try MCPConfig(servers: [try server(named: "notion", enabled: false)])

    // when
    let targets = try MCPCommand.probeTargets(named: "notion", config: config)

    // then
    #expect(targets.map(\.name) == ["notion"])
  }

  @Test func probeRefusesAServerTheConfigDoesNotDeclare() throws {
    // given
    let config = try MCPConfig(servers: [try server(named: "linear")])

    // when
    let thrown = #expect(throws: ExitCode.self) {
      try MCPCommand.probeTargets(named: "typo", config: config)
    }

    // then
    #expect(thrown == ExitCode(ClawExitCode.configInvalid.rawValue))
  }

  @Test func probeWithNothingEnabledSaysWhyRatherThanReportingNothing() throws {
    // given
    let config = try MCPConfig(servers: [try server(named: "linear", enabled: false)])

    // when
    let report = MCPCommand.nothingToProbeReport(config: config)

    // then
    #expect(report.checks.map(\.value) == ["no enabled servers to probe"])
    #expect(report.ok)
  }

  // MARK: - Live path

  @Test func probeReportsTheToolCountEachServerWouldContribute() async throws {
    // given — a real SDK server behind the HTTP seam
    let remote = ScriptedMCPHTTPServer(tools: [
      RemoteTool(name: "list_issues"),
      RemoteTool(name: "create_issue"),
    ])

    // when
    let outcomes = await MCPProbe.run(
      servers: [try server(named: "linear")],
      credentials: [:],
      http: remote,
      logger: Self.silentLogger
    )

    // then
    #expect(outcomes.count == 1)
    #expect(outcomes[0].server == "linear")
    #expect(outcomes[0].status == .ok(toolCount: 2))
    #expect(MCPDoctorRows.bootRows(outcomes: outcomes).map(\.value) == ["2"])
  }

  @Test func probeCountsWhatTheFilterActuallyAdmits() async throws {
    // given — the server offers two tools, the owner admitted one
    let remote = ScriptedMCPHTTPServer(tools: [
      RemoteTool(name: "list_issues"),
      RemoteTool(name: "create_issue"),
    ])
    let filtered = try MCPServerConfig(
      name: "linear",
      url: "https://linear.test.invalid/mcp",
      tools: MCPToolFilter(include: ["list_issues"])
    )

    // when
    let outcomes = await MCPProbe.run(
      servers: [filtered],
      credentials: [:],
      http: remote,
      logger: Self.silentLogger
    )

    // then — a probe answers about the daemon's catalog, not the server's brochure
    #expect(outcomes[0].status == .ok(toolCount: 1))
  }

  @Test func probeReportsAnUnreachableServerAsSkippedAndFailsTheReport() async throws {
    // given — an executor with nothing scripted refuses every attempt, as an unreachable host would
    let outcomes = await MCPProbe.run(
      servers: [try server(named: "linear")],
      credentials: [:],
      http: ScriptedHTTPExecutor([]),
      logger: Self.silentLogger
    )

    // when
    let report = DoctorReport(checks: MCPDoctorRows.bootRows(outcomes: outcomes))

    // then — probe is live proof, so a server that cannot answer has to exit non-zero
    #expect(report.ok == false)
    let row = try #require(report.checks.first)
    #expect(row.key == "mcp.linear.tools")
    #expect(row.value.hasPrefix("skipped: "))
  }

  @Test func probeSendsTheBoundTokenAndOnlyReportsTheCount() async throws {
    // given
    let remote = ScriptedMCPHTTPServer(tools: [RemoteTool(name: "list_issues")])

    // when
    let outcomes = await MCPProbe.run(
      servers: [try server(named: "linear")],
      credentials: ["linear": .token("linear-token")],
      http: remote,
      logger: Self.silentLogger
    )

    // then — every exchange authenticated with the bound token, and it appears in no row
    let sent = await remote.authorizationHeaders
    #expect(sent.isEmpty == false)
    #expect(Set(sent) == ["Bearer linear-token"])
    let rendered = DoctorReport(checks: MCPDoctorRows.bootRows(outcomes: outcomes)).renderText()
    #expect(rendered.contains("linear-token") == false)
  }
}

// MARK: - Fixtures

private typealias RemoteTool = ScriptedMCPHTTPServer.RemoteTool

private extension MCPProbeCommandTests {
  static let silentLogger = Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })

  func server(named name: String, enabled: Bool = true) throws -> MCPServerConfig {
    try MCPServerConfig(name: name, url: "https://\(name).test.invalid/mcp", enabled: enabled)
  }
}

/// A state root as `secrets seal` leaves it, so the token map has a key to seal under.
private func makeSealedStateRoot() throws -> URL {
  let stateRoot = try makeTemporaryRoot(prefix: "claw-mcp-ops")
  try EncryptedFileSecretStore.seal(
    Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
    stateRoot: stateRoot
  )
  return stateRoot
}
