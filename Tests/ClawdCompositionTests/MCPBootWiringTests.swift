import ClawCore
import ClawGateway
import ClawMCP
import ClawSecrets
import Foundation
import Logging
import Testing

@testable import clawd

/// The redaction union the whole process inherits, built before the first logger exists.
@Suite struct MCPBootInputsTests {
  @Test("every stored MCP token joins the secret store's redaction values")
  func tokensJoinTheRedactionUnion() throws {
    // given
    let inputs = MCPBootInputs(
      config: try MCPConfig(servers: [try server(named: "linear"), try server(named: "notion")]),
      credentials: ["linear": .token("linear-token"), "notion": .token("notion-token")],
      credentialRedactionValues: ["linear-token", "notion-token"]
    )

    // when
    let values = inputs.redactionValues(
      with: Secrets(telegramBotToken: "tg-token", llmApiKey: "sk-key", searchApiKey: nil)
    )

    // then
    #expect(Set(values) == ["tg-token", "sk-key", "linear-token", "notion-token"])
  }

  @Test("a token bound to a different URL is redacted but never sent")
  func rePointedTokenIsTreatedAsAbsent() throws {
    // given
    let inputs = MCPBootInputs(
      config: try MCPConfig(servers: [try server(named: "linear")]),
      credentials: ["linear": .boundToDifferentURL],
      credentialRedactionValues: ["old-host-token"]
    )

    // when
    let values = inputs.redactionValues(
      with: Secrets(telegramBotToken: "tg-token", llmApiKey: nil, searchApiKey: nil)
    )

    // then
    #expect(values == ["tg-token", "old-host-token"])
    #expect(inputs.token(for: "linear") == nil)
  }

  @Test("the run command hands every loaded secret to the logging bootstrap")
  func runCommandBootstrapsLoggingWithTheCompleteRedactionSet() throws {
    // given
    let inputs = MCPBootInputs(
      config: try MCPConfig(servers: [try server(named: "linear")]),
      credentials: ["linear": .token("mcp-linear-secret-token")],
      credentialRedactionValues: ["mcp-linear-secret-token"]
    )
    let secrets = Secrets(
      telegramBotToken: "tg-token",
      llmApiKey: "llm-secret-token",
      searchApiKey: "search-secret-token"
    )
    let capture = BootLoggingCapture()

    // when
    let logging = RunCommand.makeBootLogging(
      secrets: secrets,
      mcp: inputs,
      bootstrap: { values in
        capture.record(values)
        return Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })
      }
    )

    // then
    let expected = Set([
      "tg-token",
      "llm-secret-token",
      "search-secret-token",
      "mcp-linear-secret-token",
    ])
    #expect(Set(capture.values) == expected)
    #expect(Set(logging.redactionValues) == expected)
  }

  private func server(named name: String) throws -> MCPServerConfig {
    try MCPServerConfig(name: name, url: "https://\(name).test.invalid/mcp")
  }
}

private final class BootLoggingCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func record(_ values: [String]) {
    lock.lock()
    defer { lock.unlock() }
    recorded = values
  }
}

/// The rows both health surfaces are built from — `clawd doctor` offline, and the running daemon's
/// reporter with the boot outcomes appended.
@Suite struct MCPDoctorRowsTests {
  @Test("an empty catalog reports one row and fails nothing")
  func emptyCatalogReportsOneRow() {
    // given, when
    let rows = MCPDoctorRows.rows(config: .empty, credentials: [:])

    // then
    #expect(rows.map(\.key) == ["mcp"])
    #expect(rows.contains { $0.ok == false } == false)
    #expect(rows[0].group == .mcp)
  }

  @Test(
    "a server's row states its token state, and only a re-pointed binding fails",
    arguments: [
      (MCPCredentialLoad.absent, "no token", true),
      (MCPCredentialLoad.token("secret"), "token set", true),
      (
        MCPCredentialLoad.boundToDifferentURL,
        "token bound to a different URL; re-run clawd mcp set-token", false
      ),
    ]
  )
  func tokenStateReachesTheRow(load: MCPCredentialLoad, expected: String, ok: Bool) throws {
    // given
    let config = try MCPConfig(servers: [
      try MCPServerConfig(name: "linear", url: "https://mcp.test.invalid/mcp")
    ])

    // when
    let rows = MCPDoctorRows.rows(config: config, credentials: ["linear": load])

    // then
    let row = try #require(rows.first { $0.key == "mcp.linear" })
    #expect(row.value.contains(expected))
    #expect(row.ok == ok)
    #expect(try #require(rows.first).value == "1 configured, 1 enabled")
  }

  @Test("a disabled server and its filter are both named in the row")
  func disabledServerAndFilterAreNamed() throws {
    // given
    let config = try MCPConfig(servers: [
      try MCPServerConfig(
        name: "linear",
        url: "https://mcp.test.invalid/mcp",
        enabled: false,
        tools: MCPToolFilter(include: ["list_issues"], exclude: ["create_issue"])
      )
    ])

    // when
    let rows = MCPDoctorRows.rows(config: config, credentials: [:])

    // then
    let row = try #require(rows.first { $0.key == "mcp.linear" })
    #expect(row.value.contains("disabled"))
    // Include wins, so the row must not offer the exclusion the loader ignores.
    #expect(row.value.contains("include: list_issues"))
    #expect(row.value.contains("create_issue") == false)
    #expect(try #require(rows.first).value == "1 configured, 0 enabled")
  }

  @Test("boot rows carry the tool count, and a skip carries its reason")
  func bootRowsReportBothOutcomes() {
    // given
    let outcomes = [
      MCPServerOutcome(server: "linear", status: .ok(toolCount: 3)),
      MCPServerOutcome(server: "notion", status: .skipped(reason: "connection refused")),
    ]

    // when
    let rows = MCPDoctorRows.bootRows(outcomes: outcomes)

    // then
    #expect(rows.map(\.key) == ["mcp.linear.tools", "mcp.notion.tools"])
    #expect(rows[0].value == "3")
    #expect(rows[0].ok)
    #expect(rows[1].value == "skipped: connection refused")
    #expect(rows[1].ok == false)
  }
}
