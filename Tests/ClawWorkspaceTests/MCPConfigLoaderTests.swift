import ClawCore
import Foundation
import Testing

@testable import ClawWorkspace

@Suite struct MCPConfigLoaderTests {
  @Test func decodesServerListWithEveryFieldSet() throws {
    // given
    let yaml = """
      servers:
        - name: linear
          url: https://mcp.linear.app/mcp
          enabled: false
          authHeader: X-Api-Key
          headers:
            X-Client: swift-claw
          connectTimeoutSeconds: 5
          requestTimeoutSeconds: 60
          tools:
            include: [list_issues, create_issue]
            risk:
              list_issues: safe
      """

    // when
    let config = try MCPConfigLoader.parse(yaml: yaml)

    // then
    let server = try #require(config.servers.first)
    #expect(config.servers.count == 1)
    #expect(config.enabledServers.isEmpty)
    #expect(server.name == "linear")
    #expect(server.url.absoluteString == "https://mcp.linear.app/mcp")
    #expect(server.enabled == false)
    #expect(server.authHeader == "X-Api-Key")
    #expect(server.headers == ["X-Client": "swift-claw"])
    #expect(server.connectTimeoutSeconds == 5)
    #expect(server.requestTimeoutSeconds == 60)
    #expect(server.tools.include == ["list_issues", "create_issue"])
    #expect(server.tools.riskLevel(for: "list_issues") == .safe)
    #expect(server.tools.riskLevel(for: "create_issue") == .ask)
  }

  @Test func appliesDefaultsWhenOnlyNameAndURLAreGiven() throws {
    // given
    let yaml = """
      servers:
        - name: docs
          url: http://127.0.0.1:8080/mcp
      """

    // when
    let config = try MCPConfigLoader.parse(yaml: yaml)

    // then
    let server = try #require(config.servers.first)
    #expect(server.enabled)
    #expect(server.headers.isEmpty)
    #expect(server.authHeader == MCPLimits.defaultAuthHeader)
    #expect(server.connectTimeoutSeconds == MCPLimits.defaultConnectTimeoutSeconds)
    #expect(server.requestTimeoutSeconds == MCPLimits.defaultRequestTimeoutSeconds)
    #expect(server.tools == .allowAll)
    #expect(server.worstCaseCallSeconds == 40)
  }

  @Test func includeWinsWhenBothFiltersArePresent() throws {
    // given
    let yaml = """
      servers:
        - name: docs
          url: https://example.com/mcp
          tools:
            include: [search]
            exclude: [search, write]
      """

    // when
    let server = try #require(MCPConfigLoader.parse(yaml: yaml).servers.first)

    // then
    #expect(server.tools.allows("search"))
    #expect(server.tools.allows("write") == false)
  }

  @Test func explicitEmptyIncludeExposesNoRemoteTools() throws {
    // given
    let yaml = """
      servers:
        - name: docs
          url: https://example.com/mcp
          tools:
            include: []
      """

    // when
    let server = try #require(MCPConfigLoader.parse(yaml: yaml).servers.first)

    // then
    #expect(server.tools.include == [])
    #expect(server.tools.allows("search") == false)
  }

  @Test func emptyDocumentAndAbsentServerListBothYieldNoServers() throws {
    // given
    let documents = ["", "# only a comment\n", "servers:\n"]

    // when
    let configs = try documents.map { try MCPConfigLoader.parse(yaml: $0) }

    // then
    #expect(configs.allSatisfy { $0.servers.isEmpty })
  }

  @Test(arguments: [
    (
      "unknown top-level key",
      yaml: "server:\n  - name: docs\n",
      expected: MCPConfigError.unknownKey("server")
    ),
    (
      "unknown server key",
      yaml: "servers:\n  - name: docs\n    url: https://example.com/mcp\n    timeout: 5\n",
      expected: MCPConfigError.unknownKey("servers[0].timeout")
    ),
    (
      "unknown tools key",
      yaml:
        "servers:\n  - name: docs\n    url: https://example.com/mcp\n    tools:\n      only: []\n",
      expected: MCPConfigError.unknownKey("servers[0].tools.only")
    ),
    (
      "missing url",
      yaml: "servers:\n  - name: docs\n",
      expected: MCPConfigError.missingValue(key: "servers[0].url")
    ),
    (
      "unparseable url",
      yaml: "servers:\n  - name: docs\n    url: \"not a url\"\n",
      expected: MCPConfigError.invalidURL(server: "docs", value: "not a url")
    ),
    (
      "non-http scheme",
      yaml: "servers:\n  - name: docs\n    url: file:///etc/passwd\n",
      expected: MCPConfigError.unsupportedScheme(server: "docs", value: "file")
    ),
    (
      "duplicate name after sanitization",
      yaml: """
      servers:
        - name: my-docs
          url: https://example.com/a
        - name: my_docs
          url: https://example.com/b
      """,
      expected: MCPConfigError.duplicateServerName("my_docs")
    ),
    (
      "dangerous risk override",
      yaml: """
      servers:
        - name: docs
          url: https://example.com/mcp
          tools:
            risk:
              wipe: dangerous
      """,
      expected: MCPConfigError.dangerousRiskOverride(server: "docs", tool: "wipe")
    ),
    (
      "unknown risk tier",
      yaml: """
      servers:
        - name: docs
          url: https://example.com/mcp
          tools:
            risk:
              wipe: maybe
      """,
      expected: MCPConfigError.invalidValue(key: "servers[0].tools.risk.wipe", value: "maybe")
    ),
    (
      "out-of-range timeout",
      yaml: """
      servers:
        - name: docs
          url: https://example.com/mcp
          requestTimeoutSeconds: 0
      """,
      expected: MCPConfigError.invalidValue(key: "requestTimeoutSeconds", value: "0")
    ),
    (
      "auth header shadowed by a static header",
      yaml: """
      servers:
        - name: docs
          url: https://example.com/mcp
          headers:
            authorization: Bearer pasted-token
      """,
      expected: MCPConfigError.invalidValue(key: "headers", value: "Authorization")
    ),
    (
      "server entry is not a mapping",
      yaml: "servers:\n  - docs\n",
      expected: MCPConfigError.invalidValue(key: "servers[0]", value: "expected a mapping")
    ),
    (
      "servers is not a list",
      yaml: "servers: docs\n",
      expected: MCPConfigError.invalidValue(key: "servers", value: "expected a list")
    ),
  ]) func rejectsInvalidConfig(
    description: String,
    yaml: String,
    expected: MCPConfigError
  ) {
    // given / when / then
    #expect(throws: expected) {
      try MCPConfigLoader.parse(yaml: yaml)
    }
  }

  @Test func malformedYAMLIsReportedAsMalformed() {
    // given
    let yaml = "servers:\n  - name: docs\n   url: [unclosed\n"

    // when / then
    #expect(throws: MCPConfigError.self) {
      try MCPConfigLoader.parse(yaml: yaml)
    }
  }

  @Test func missingProbedFileLeavesTheFeatureOff() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = MCPConfigSource.probed(root.appendingPathComponent(MCPLimits.configFileName))

    // when
    let config = try MCPConfigLoader.load(from: source)

    // then
    #expect(config.servers.isEmpty)
  }

  @Test func missingExplicitFileIsAnOwnerError() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("typo.yaml")

    // when / then
    #expect(throws: MCPConfigError.unreadableFile(path: fileURL.path)) {
      try MCPConfigLoader.load(from: .explicit(fileURL))
    }
  }

  @Test func readsAPresentFileFromDisk() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(
      atRelativePath: MCPLimits.configFileName,
      content: "servers:\n  - name: docs\n    url: https://example.com/mcp\n",
      under: root
    )
    let source = MCPConfigSource.probed(root.appendingPathComponent(MCPLimits.configFileName))

    // when
    let config = try MCPConfigLoader.load(from: source)

    // then
    #expect(config.servers.map(\.name) == ["docs"])
  }

  @Test func presentButNonUTF8FileIsUnreadable() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRawFile(
      atRelativePath: MCPLimits.configFileName,
      bytes: [0xFF, 0xFE, 0xFD],
      under: root
    )
    let fileURL = root.appendingPathComponent(MCPLimits.configFileName)

    // when / then
    #expect(throws: MCPConfigError.unreadableFile(path: fileURL.path)) {
      try MCPConfigLoader.load(from: .probed(fileURL))
    }
  }
}
