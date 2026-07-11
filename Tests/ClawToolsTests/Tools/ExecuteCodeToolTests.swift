import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawTools

@Suite struct ExecuteCodeToolTests {
  private struct Workspace {
    let root: URL
    let outside: URL
  }

  private func makeWorkspace() throws -> Workspace {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "claw-execute-tool-\(UUID().uuidString)",
      isDirectory: true
    )
    let root = base.appendingPathComponent("workspace", isDirectory: true)
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    return Workspace(root: root, outside: outside)
  }

  private func write(_ data: Data, relativePath: String, workspace: Workspace) throws {
    let destination = workspace.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destination)
  }

  private func makeTool(
    workspace: Workspace,
    backend: FakeExecutionBackend = FakeExecutionBackend(),
    allowEgress: Bool = false,
    secrets: [String] = []
  ) -> ExecuteCodeTool {
    ExecuteCodeTool(
      workspaceRoot: workspace.root,
      backend: backend,
      settings: ExecuteCodeSettings(
        memoryMiB: 1024,
        cpus: 4,
        timeout: .seconds(30),
        allowEgress: allowEgress
      ),
      redactor: SecretRedactor(secretValues: secrets)
    )
  }

  private func arguments(
    language: String = "python",
    code: String = "print('hello')",
    stage: [String] = [],
    network: Bool = false
  ) -> JSONValue {
    .object([
      "language": .string(language),
      "code": .string(code),
      "stage": .array(stage.map(JSONValue.string)),
      "network": .bool(network),
    ])
  }

  private func prepared(_ resolution: PreparedActionResolution?) throws -> PreparedToolAction {
    guard case .prepared(let action) = resolution else {
      Issue.record("expected prepared action, got \(String(describing: resolution))")
      throw PreparationFailure()
    }
    return action
  }

  private func refused(_ resolution: PreparedActionResolution?) -> Bool {
    guard case .refused = resolution else {
      return false
    }
    return true
  }

  private struct PreparationFailure: Error {}
}

extension ExecuteCodeToolTests {
  @Test func definitionDeclaresTheClosedDangerousSurface() throws {
    // given
    let workspace = try makeWorkspace()
    let tool = makeTool(workspace: workspace)

    // when
    let definition = tool.definition

    // then
    #expect(definition.name == "execute_code")
    #expect(definition.riskLevel == .dangerous)
    #expect(definition.egressClass == .none)
  }

  @Test func unknownLanguageAndOversizeCodeRefuse() async throws {
    // given
    let workspace = try makeWorkspace()
    let tool = makeTool(workspace: workspace)
    let oversize = String(repeating: "x", count: ExecuteCodeTool.maxCodeBytes + 1)

    // when
    let language = await tool.prepareAction(arguments: arguments(language: "ruby"))
    let code = await tool.prepareAction(arguments: arguments(code: oversize))

    // then
    #expect(refused(language))
    #expect(refused(code))
  }

  @Test func rawOptionalDefaultsAreExplicitAndWrongTypesRefuse() async throws {
    // given
    let workspace = try makeWorkspace()
    let tool = makeTool(workspace: workspace)
    let minimal: JSONValue = .object([
      "language": .string("sh"),
      "code": .string("echo hello"),
    ])
    let badStage: JSONValue = .object([
      "language": .string("sh"),
      "code": .string("echo hello"),
      "stage": .string("notes.txt"),
    ])
    let badNetwork: JSONValue = .object([
      "language": .string("sh"),
      "code": .string("echo hello"),
      "network": .string("false"),
    ])

    // when
    let action = try await prepared(tool.prepareAction(arguments: minimal))
    let recorded = try #require(JSONValue.parse(action.canonicalArgsJSON)?.objectValue)
    let stage = await tool.prepareAction(arguments: badStage)
    let network = await tool.prepareAction(arguments: badNetwork)

    // then
    #expect(recorded["language"] == .string("sh"))
    #expect(recorded["network"] == .bool(false))
    #expect(recorded["readsPrivateData"] == .bool(false))
    #expect(recorded["stage"] == .array([]))
    #expect(action.canonicalTarget.hasPrefix("code_exec:sh:"))
    #expect(refused(stage))
    #expect(refused(network))
  }

  @Test func absoluteDotDotAndSymlinkEscapesRefuse() async throws {
    // given
    let workspace = try makeWorkspace()
    try "outside".write(
      to: workspace.outside.appendingPathComponent("secret.txt"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createSymbolicLink(
      at: workspace.root.appendingPathComponent("escape.txt"),
      withDestinationURL: workspace.outside.appendingPathComponent("secret.txt")
    )
    let tool = makeTool(workspace: workspace)

    // when
    let absolute = await tool.prepareAction(
      arguments: arguments(stage: [workspace.outside.appendingPathComponent("secret.txt").path])
    )
    let dotDot = await tool.prepareAction(arguments: arguments(stage: ["../outside/secret.txt"]))
    let symlink = await tool.prepareAction(arguments: arguments(stage: ["escape.txt"]))
    let missing = await tool.prepareAction(arguments: arguments(stage: ["missing.txt"]))

    // then
    #expect(refused(absolute))
    #expect(refused(dotDot))
    #expect(refused(symlink))
    #expect(refused(missing))
  }

  @Test func directoriesAndExceededStageCapsRefuse() async throws {
    // given
    let workspace = try makeWorkspace()
    try FileManager.default.createDirectory(
      at: workspace.root.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try write(
      Data(repeating: 0x61, count: ExecuteCodeTool.maxStagedFileBytes + 1),
      relativePath: "large.bin",
      workspace: workspace
    )
    let countPaths = (0...ExecuteCodeTool.maxStagedFiles).map { index in
      "count-\(index).txt"
    }
    for path in countPaths {
      try write(Data("x".utf8), relativePath: path, workspace: workspace)
    }
    let totalPaths = (0..<4).map { index in
      "total-\(index).bin"
    }
    for path in totalPaths {
      try write(
        Data(repeating: 0x62, count: ExecuteCodeTool.maxStagedFileBytes),
        relativePath: path,
        workspace: workspace
      )
    }
    try write(Data([0x63]), relativePath: "total-over.bin", workspace: workspace)
    let tool = makeTool(workspace: workspace)

    // when
    let directory = await tool.prepareAction(arguments: arguments(stage: ["folder"]))
    let perFile = await tool.prepareAction(arguments: arguments(stage: ["large.bin"]))
    let count = await tool.prepareAction(arguments: arguments(stage: countPaths))
    let total = await tool.prepareAction(
      arguments: arguments(stage: totalPaths + ["total-over.bin"])
    )

    // then
    #expect(refused(directory))
    #expect(refused(perFile))
    #expect(refused(count))
    #expect(refused(total))
  }

  @Test func networkNeedsTheOwnerConfigSwitch() async throws {
    // given
    let workspace = try makeWorkspace()

    // when
    let blocked = await makeTool(workspace: workspace).prepareAction(
      arguments: arguments(network: true)
    )
    let enabled = await makeTool(workspace: workspace, allowEgress: true).prepareAction(
      arguments: arguments(network: true)
    )

    // then
    #expect(refused(blocked))
    #expect(try prepared(enabled).canExfiltrate)
  }

  @Test func normalizedDuplicateAndReservedBasenamesRefuse() async throws {
    // given
    let workspace = try makeWorkspace()
    try write(Data("a".utf8), relativePath: "A.txt", workspace: workspace)
    try write(Data("b".utf8), relativePath: "a.TXT", workspace: workspace)
    try write(Data("c".utf8), relativePath: ".CLAWD-ENTRYPOINT.PY", workspace: workspace)
    try write(Data("d".utf8), relativePath: "résumé.txt", workspace: workspace)
    try write(
      Data("e".utf8),
      relativePath: "re\u{301}sume\u{301}.txt",
      workspace: workspace
    )
    let tool = makeTool(workspace: workspace)

    // when
    let duplicate = await tool.prepareAction(arguments: arguments(stage: ["A.txt", "a.TXT"]))
    let reserved = await tool.prepareAction(
      arguments: arguments(stage: [".CLAWD-ENTRYPOINT.PY"])
    )
    let unicodeDuplicate = await tool.prepareAction(
      arguments: arguments(stage: ["résumé.txt", "re\u{301}sume\u{301}.txt"])
    )

    // then
    #expect(refused(duplicate))
    #expect(refused(reserved))
    #expect(refused(unicodeDuplicate))
  }

  @Test func preparedJSONBindsEveryStageAndPrivateClassification() async throws {
    // given
    let workspace = try makeWorkspace()
    try write(Data("input text".utf8), relativePath: "notes/input.txt", workspace: workspace)
    try write(Data("private text".utf8), relativePath: "MEMORY.md", workspace: workspace)
    let tool = makeTool(workspace: workspace)
    let canonicalRoot = try #require(WorkspacePathContainment.canonicalPath(workspace.root.path))

    // when
    let action = try await prepared(
      tool.prepareAction(
        arguments: arguments(stage: ["notes/input.txt", "MEMORY.md"])
      )
    )
    let decoded = try #require(JSONValue.parse(action.canonicalArgsJSON)?.objectValue)
    guard case .array(let stages) = decoded["stage"] else {
      Issue.record("recorded stage was not an array")
      return
    }
    let inputStage = try #require(
      stages.first { stage in
        stage.objectValue?["path"] == .string("notes/input.txt")
      }?.objectValue
    )
    let memoryStage = try #require(
      stages.first { stage in
        stage.objectValue?["path"] == .string("MEMORY.md")
      }?.objectValue
    )

    // then
    #expect(stages.count == 2)
    #expect(decoded["network"] == .bool(false))
    #expect(decoded["readsPrivateData"] == .bool(true))
    #expect(action.guardTexts == ["print('hello')", "input text", "private text"])
    #expect(action.canExfiltrate == false)
    let hashPrefix = ApprovalArgsHash.sha256Hex(action.canonicalArgsJSON).prefix(16)
    #expect(action.canonicalTarget == "code_exec:python:\(hashPrefix)")
    #expect(inputStage["bytes"]?.numberValue == 10)
    #expect(inputStage["sha256"] == .string(SHA256Digest.hex(Data("input text".utf8))))
    #expect(memoryStage["bytes"]?.numberValue == 12)
    #expect(memoryStage["sha256"] == .string(SHA256Digest.hex(Data("private text".utf8))))
    for stage in stages {
      let object = try #require(stage.objectValue)
      #expect(object["realpath"]?.stringValue?.hasPrefix(canonicalRoot + "/") == true)
      #expect(object["sha256"]?.stringValue?.count == 64)
      #expect(object["bytes"]?.numberValue != nil)
    }
  }

  @Test func boundedReaderRefusesOneBytePastItsLimit() throws {
    // given
    let workspace = try makeWorkspace()
    let path = workspace.root.appendingPathComponent("race.bin").path
    try Data(repeating: 0x61, count: 33).write(to: URL(fileURLWithPath: path))

    // when
    let data = try ExecuteCodeTool.readBoundedFile(atPath: path, maxBytes: 32)

    // then
    #expect(data == nil)
  }
}

extension ExecuteCodeToolTests {
  @Test func presentationShowsTheCompleteRedactedScriptAndEveryStage() async throws {
    // given
    let workspace = try makeWorkspace()
    try write(Data("one".utf8), relativePath: "notes/one.txt", workspace: workspace)
    try write(Data("two".utf8), relativePath: "two.txt", workspace: workspace)
    let secret = "approval-secret-value"
    let code = "print('start')\nprint('\(secret)')\nprint('end')"
    let tool = makeTool(workspace: workspace, secrets: [secret])

    // when
    let action = try await prepared(
      tool.prepareAction(
        arguments: arguments(code: code, stage: ["notes/one.txt", "two.txt"])
      )
    )
    let preview = try #require(action.presentation.contentPreview)
    let canonicalRoot = try #require(WorkspacePathContainment.canonicalPath(workspace.root.path))
    let oneHash = SHA256Digest.hex(Data("one".utf8)).prefix(16)
    let twoHash = SHA256Digest.hex(Data("two".utf8)).prefix(16)

    // then
    #expect(preview.contains("```python"))
    #expect(preview.contains("print('start')"))
    #expect(preview.contains("print('end')"))
    #expect(preview.contains(secret) == false)
    #expect(preview.contains(SecretRedactor.replacement))
    #expect(preview.contains("notes/one.txt"))
    #expect(preview.contains("two.txt"))
    #expect(preview.contains("3 B"))
    #expect(preview.contains(canonicalRoot + "/notes/one.txt"))
    #expect(preview.contains(canonicalRoot + "/two.txt"))
    #expect(preview.contains(String(oneHash)))
    #expect(preview.contains(String(twoHash)))
    #expect(
      action.presentation.blastRadius
        == "run python · egress: no · 4 CPU / 1024 MiB · code \(code.utf8.count) B · 2 staged file(s), 6 B"
    )
  }

  @Test func maximumCodePreviewIsNeverTruncated() async throws {
    // given
    let workspace = try makeWorkspace()
    let code = String(repeating: "x", count: ExecuteCodeTool.maxCodeBytes)
    let tool = makeTool(workspace: workspace)

    // when
    let action = try await prepared(tool.prepareAction(arguments: arguments(code: code)))
    let preview = try #require(action.presentation.contentPreview)

    // then
    #expect(preview.contains(code))
    #expect(preview.contains(ToolOutputCap.truncationMarker) == false)
  }

  @Test func networkedPresentationNamesEgressAndWarning() async throws {
    // given
    let workspace = try makeWorkspace()
    let tool = makeTool(workspace: workspace, allowEgress: true)

    // when
    let action = try await prepared(
      tool.prepareAction(arguments: arguments(network: true))
    )

    // then
    #expect(action.presentation.blastRadius.contains("egress: yes"))
    #expect(action.presentation.warnings.count == 1)
    #expect(action.presentation.warnings[0].contains("send data out"))
  }
}
