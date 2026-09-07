import ClawCore
import Foundation
import Testing

@testable import ClawCoder

struct CodexBackendTests {
  @Test func cliBoundary() async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    let task = "Fix 'quotes'\n$(touch should-not-exist) \"exact\""
    let request = CoderRequest(
      source: .local(path: fixture.git.source.path),
      task: task,
      workspace: .inPlace,
      startRef: nil,
      deliverable: .localChanges,
      baseBranch: nil,
      instructions: "Use Swift",
      publishExistingChanges: false
    )
    let invocation = try await fixture.invocation(request)
    let starting = try await fixture.git.git(["rev-parse", "HEAD"])
    try fixture.write("action", "printf 'changed\\n' > file.txt")
    try fixture.report(["summary": "token-fixture Done", "checks": ["token-fixture check"]])
    let backend = try fixture.backend(
      extraEnvironment: [
        "UNRELATED_SENTINEL": "private", "GH_TOKEN": "token-fixture",
        "CLAW_TELEGRAM_BOT_TOKEN": "telegram-private",
      ],
      profile: "coding"
    )

    // when
    let result = await backend.run(invocation) { _ in }

    // then
    #expect(backend.credentialSources["GH_TOKEN"] == "GH_TOKEN")
    #expect(backend.credentialSources["GH_CONFIG_DIR"] == fixture.git.root.path + "/.config/gh")
    #expect(result.state == .succeeded)
    #expect(result.startingCommit == starting)
    #expect(result.baselineObserved)
    #expect(result.changedFiles == ["file.txt"])
    #expect(result.branch == "trunk")
    #expect(result.reportedUsage == ["input_tokens": 12, "output_tokens": 4])
    #expect(result.summary.contains(SecretRedactor.replacement))
    #expect(!result.reportedChecks.joined().contains("token-fixture"))
    let argv = try fixture.read("argv").split(separator: "\0").map(String.init)
    let schemaPath = try #require(argv.firstIndex(of: "--output-schema")).advanced(by: 1)
    let resultPath = try #require(argv.firstIndex(of: "-o")).advanced(by: 1)
    #expect(
      argv == [
        "exec", "--json", "--approve-for-me", "-c",
        "approval_policy=\"\(CodexBackend.approvalPolicy)\"",
        "--skip-git-repo-check", "--ephemeral", "--color", "never", "-C", fixture.git.source.path,
        "--output-schema", argv[schemaPath], "-o", argv[resultPath], "--profile", "coding", "-",
      ]
    )
    #expect(try fixture.read("stdin").contains(task))
    #expect(try fixture.read("stdin").contains(invocation.jobID.uuidString.lowercased()))
    let environment = try fixture.read("environment")
    #expect(!environment.contains("UNRELATED_SENTINEL"))
    #expect(!environment.contains("telegram-private"))
    #expect(environment.contains("GH_TOKEN=token-fixture"))
    #expect(environment.contains("CODEX_HOME=\(fixture.git.root.path)/config"))
    #expect(!FileManager.default.fileExists(atPath: argv[schemaPath]))
    #expect(!FileManager.default.fileExists(atPath: argv[resultPath]))
    #expect(!FileManager.default.fileExists(atPath: fixture.git.source.path + "/should-not-exist"))
    try expectSchema(fixture.read("schema"))
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.git.root.appendingPathComponent("schema").path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test(arguments: [
    "blocked", "failed", "eventFailed", "exit", "terminal", "missing", "invalid", "symlink",
    "largeReport",
    "largeFrame",
  ])
  func completionMatrix(mode: String) async throws {
    // given
    let fixture = try await CodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.git.root) }
    switch mode {
    case "blocked", "failed": try fixture.report(["status": mode, "error": "Worker reason"])
    case "eventFailed": try fixture.write("events", "{\"type\":\"turn.failed\"}\n")
    case "exit": try fixture.write("exit", "7")
    case "terminal": try fixture.write("events", "{\"type\":\"item.completed\"}\n")
    case "missing": try fixture.write("no-report", "")
    case "invalid":
      let data = Data(try fixture.read("report").utf8)
      var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      object.removeValue(forKey: "starting_commit")
      try JSONSerialization.data(withJSONObject: object).write(
        to: fixture.git.root.appendingPathComponent("report")
      )
    case "symlink":
      try fixture.write("no-report", "")
      try fixture.write("action", "ln -s \"$(dirname \"$0\")/report\" \"$1\"")
    case "largeReport":
      try fixture.report(["summary": String(repeating: "x", count: CodexReport.byteLimit)])
    case "largeFrame":
      let event: [String: String] = [
        "type": "future.event",
        "padding": String(repeating: "x", count: CodexEvents.frameByteLimit),
      ]
      let bytes = try JSONSerialization.data(withJSONObject: event)
      let eventText = try #require(String(data: bytes, encoding: .utf8))
      try fixture.write("events", eventText + "\n" + fixture.read("events"))
    default: break
    }
    let invocation = try await fixture.invocation()

    // when
    let result = await (try fixture.backend()).run(invocation) { _ in }

    // then
    #expect(result.state == .failed)
    #expect(result.failure != nil)
    if mode == "blocked" {
      #expect(result.failure?.stage == .permission)
    }
    if ["failed", "exit", "eventFailed"].contains(mode) {
      #expect(result.failure?.stage == .execution)
    }
    if ["terminal", "missing", "invalid", "symlink", "largeReport", "largeFrame"].contains(mode) {
      #expect(result.failure?.stage == .protocolOutput)
    }
  }
}

// MARK: - Outbound schema contract

private extension CodexBackendTests {
  func expectSchema(_ text: String) throws {
    let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8))
    let schema = try #require(decoded as? [String: Any])
    #expect(Set(schema.keys) == ["type", "additionalProperties", "required", "properties"])
    #expect(schema["type"] as? String == "object")
    #expect(schema["additionalProperties"] as? Bool == false)
    let expectedKeys = Set(CodexReport.CodingKeys.allCases.map(\.rawValue))
    let required = try #require(schema["required"] as? [String])
    #expect(Set(required) == expectedKeys)
    #expect(required.count == expectedKeys.count)
    let properties = try #require(schema["properties"] as? [String: [String: Any]])
    #expect(Set(properties.keys) == expectedKeys)
    let status = try #require(properties[CodexReport.CodingKeys.status.rawValue])
    #expect(Set(status.keys) == ["type", "enum"])
    #expect(status["type"] as? String == "string")
    let statuses = try #require(status["enum"] as? [String])
    let expectedStatuses = Set([
      CodexReportStatus.succeeded.rawValue, CodexReportStatus.blocked.rawValue,
      CodexReportStatus.failed.rawValue,
    ])
    #expect(Set(statuses) == expectedStatuses)
    #expect(statuses.count == expectedStatuses.count)
    #expect(
      properties[CodexReport.CodingKeys.summary.rawValue] as? [String: String] == [
        "type": "string"
      ]
    )
    let nullableStrings: [CodexReport.CodingKeys] = [
      .startingCommit, .baseBranch, .branch, .commit, .prURL, .error,
    ]
    for key in nullableStrings {
      let property = try #require(properties[key.rawValue])
      #expect(Set(property.keys) == ["type"])
      let types = try #require(property["type"] as? [String])
      #expect(Set(types) == ["string", "null"])
      #expect(types.count == 2)
    }
    for key in [CodexReport.CodingKeys.changedFiles, .checks] {
      let property = try #require(properties[key.rawValue])
      #expect(Set(property.keys) == ["type", "items"])
      if key == .changedFiles {
        let types = try #require(property["type"] as? [String])
        #expect(Set(types) == ["array", "null"])
        #expect(types.count == 2)
      } else {
        #expect(property["type"] as? String == "array")
      }
      #expect(property["items"] as? [String: String] == ["type": "string"])
    }
  }
}
