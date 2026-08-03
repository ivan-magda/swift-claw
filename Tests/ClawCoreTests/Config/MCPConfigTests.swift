import Foundation
import Testing

@testable import ClawCore

@Suite struct MCPConfigTests {
  private typealias EnvKey = AppConfig.EnvKey

  private func env(_ overrides: [String: String] = [:]) -> [String: String] {
    [
      EnvKey.llmBaseURL: "http://localhost:1234/v1",
      EnvKey.llmModel: "gpt-4o",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ].merging(overrides) { _, override in override }
  }

  @Test func unsetPathProbesTheStateRoot() throws {
    // given
    let environment = env()

    // when
    let config = try AppConfig.load(environment: environment)

    // then
    #expect(config.mcpConfigSource.isExplicit == false)
    #expect(
      config.mcpConfigSource.url
        == config.stateRoot.appendingPathComponent(MCPLimits.configFileName)
    )
  }

  @Test func setPathIsExplicitAndTakesPrecedence() throws {
    // given
    let environment = env([EnvKey.mcpConfigPath: "/etc/claw/servers.yaml"])

    // when
    let config = try AppConfig.load(environment: environment)

    // then
    #expect(config.mcpConfigSource == .explicit(URL(fileURLWithPath: "/etc/claw/servers.yaml")))
  }

  @Test func blankPathFallsBackToTheProbe() throws {
    // given
    let environment = env([EnvKey.mcpConfigPath: "   "])

    // when
    let config = try AppConfig.load(environment: environment)

    // then
    #expect(config.mcpConfigSource.isExplicit == false)
  }

  @Test func filterWithoutIncludeAppliesExclude() {
    // given
    let filter = MCPToolFilter(exclude: ["delete_issue"])

    // when / then
    #expect(filter.allows("list_issues"))
    #expect(filter.allows("delete_issue") == false)
  }

  @Test func explicitlyEmptyIncludeAllowsNoTools() {
    // given
    let filter = MCPToolFilter(include: [], exclude: [])

    // when / then
    #expect(filter.allows("list_issues") == false)
  }

  @Test func everyToolIsAskUnlessTheOwnerDowngradedIt() {
    // given
    let filter = MCPToolFilter(risk: ["list_issues": .safe])

    // when / then
    #expect(filter.riskLevel(for: "list_issues") == .safe)
    #expect(filter.riskLevel(for: "create_issue") == .ask)
  }

  @Test(arguments: [
    ("", ""),
    ("linear", "linear"),
    ("my-server", "my_server"),
    ("Acme Corp/docs", "Acme_Corp_docs"),
  ]) func sanitizesNameFragmentsToTheToolNameCharset(raw: String, expected: String) {
    // given / when
    let sanitized = MCPNaming.sanitizeFragment(raw)

    // then
    #expect(sanitized == expected)
  }

  @Test func emptyServerNameIsRejected() {
    // given / when / then
    #expect(throws: MCPConfigError.invalidServerName("  ")) {
      try MCPServerConfig(name: "  ", url: "https://example.com/mcp")
    }
  }

  @Test func aServerWithoutAHostIsRejected() {
    // given / when / then
    #expect(throws: MCPConfigError.invalidURL(server: "docs", value: "https:///mcp")) {
      try MCPServerConfig(name: "docs", url: "https:///mcp")
    }
  }

  @Test func duplicateSanitizedNamesAreRejectedAcrossTheCatalog() throws {
    // given
    let servers = [
      try MCPServerConfig(name: "my docs", url: "https://example.com/a"),
      try MCPServerConfig(name: "my.docs", url: "https://example.com/b"),
    ]

    // when / then
    #expect(throws: MCPConfigError.duplicateServerName("my_docs")) {
      try MCPConfig(servers: servers)
    }
  }

  @Test(
    arguments: [
      "Bad Header",
      "Bad:Header",
      "Ünicode",
      "Mcp-Session-Id",
      "content-type",
      "MCP-PROTOCOL-VERSION",
    ]
  ) func invalidOrReservedStaticHeadersAreRejected(_ header: String) {
    // given / when / then
    #expect(throws: MCPConfigError.self) {
      try MCPServerConfig(
        name: "docs",
        url: "https://example.com/mcp",
        headers: [header: "value"]
      )
    }
  }

  @Test(arguments: ["Bad Header", "Ünicode", "accept", "Mcp-Session-Id"])
  func invalidOrReservedAuthHeadersAreRejected(_ header: String) {
    // given / when / then
    #expect(throws: MCPConfigError.self) {
      try MCPServerConfig(
        name: "docs",
        url: "https://example.com/mcp",
        authHeader: header
      )
    }
  }

  @Test(arguments: ["line\rbreak", "line\nbreak", "control\u{0085}break"])
  func staticHeaderValuesCannotInjectControls(_ value: String) {
    // given / when / then
    #expect(throws: MCPConfigError.self) {
      try MCPServerConfig(
        name: "docs",
        url: "https://example.com/mcp",
        headers: ["X-Client": value]
      )
    }
  }

  @Test func everyConfigErrorExitsAsConfigInvalid() {
    // given
    let error = MCPConfigError.unknownKey("servers[0].timeout")

    // when / then
    #expect(error.exitCode == ClawExitCode.configInvalid.rawValue)
  }
}
