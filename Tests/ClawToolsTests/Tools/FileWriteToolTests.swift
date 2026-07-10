import ClawCore
import Foundation
import Testing

@testable import ClawTools

@Suite struct FileWriteToolTests {
  private func makeWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-filewrite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeTool(root: URL, secrets: [String] = []) -> FileWriteTool {
    FileWriteTool(workspaceRoot: root, redactor: SecretRedactor(secretValues: secrets))
  }

  // The optional overwrite models the wire's tri-state: flag absent vs explicitly false vs true.
  // swiftlint:disable:next discouraged_optional_boolean
  private func args(path: String, content: String, overwrite: Bool? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["path": .string(path), "content": .string(content)]
    if let overwrite {
      object["overwrite"] = .bool(overwrite)
    }
    return .object(object)
  }

  @Test func declaresAskTierWithNoEgress() throws {
    // given / when
    let definition = makeTool(root: try makeWorkspace()).definition

    // then — the first live ask-tier declaration in the registry
    #expect(definition.name == "file_write")
    #expect(definition.riskLevel == .ask)
    #expect(definition.egressClass == .none)
  }

  @Test func canonicalTargetResolvesACreatePathAtGateTime() throws {
    // given
    let root = try makeWorkspace()
    let canonicalRoot = try #require(WorkspacePathContainment.canonicalPath(root.path))

    // when
    let resolution = makeTool(root: root).canonicalTarget(
      arguments: args(path: "notes/plan.md", content: "hello")
    )

    // then — the approval binds to the fully-resolved absolute path (§4.3/§5.4)
    #expect(resolution == .resolved(canonicalRoot + "/notes/plan.md"))
  }

  @Test func existingFileWithoutOverwriteRefusesBeforeAnyApproval() throws {
    // given
    let root = try makeWorkspace()
    try Data("old".utf8).write(to: root.appendingPathComponent("plan.md"))
    let tool = makeTool(root: root)

    // when / then — overwrite:false (and the missing-flag default) refuse at gate time
    guard
      case .refused(let reason) = tool.canonicalTarget(
        arguments: args(path: "plan.md", content: "new", overwrite: false)
      )
    else {
      Issue.record("expected a refusal for overwrite:false on an existing file")
      return
    }
    #expect(reason.contains("already exists"))
    guard case .refused = tool.canonicalTarget(arguments: args(path: "plan.md", content: "new"))
    else {
      Issue.record("expected the missing overwrite flag to default to refuse")
      return
    }
  }

  @Test func existingFileWithOverwriteTrueResolves() throws {
    // given
    let root = try makeWorkspace()
    try Data("old".utf8).write(to: root.appendingPathComponent("plan.md"))
    let canonicalRoot = try #require(WorkspacePathContainment.canonicalPath(root.path))

    // when
    let resolution = makeTool(root: root).canonicalTarget(
      arguments: args(path: "plan.md", content: "new", overwrite: true)
    )

    // then
    #expect(resolution == .resolved(canonicalRoot + "/plan.md"))
  }

  @Test func overwriteTrueOnAMissingTargetRefusesAtGateTime() throws {
    // given — nothing exists at the path, so the prompt would render "create"; a recorded
    // overwrite:true would let execute take the replacing rename(2) branch if a file appeared
    // during the approval window, silently widening the approved blast radius (§10.2)
    let root = try makeWorkspace()

    // when / then — the flag must match the approved mode: no target, no overwrite
    guard
      case .refused(let reason) = makeTool(root: root).canonicalTarget(
        arguments: args(path: "fresh.md", content: "new", overwrite: true)
      )
    else {
      Issue.record("expected overwrite: true on a missing target to refuse at gate time")
      return
    }
    #expect(reason.contains("does not exist"))
  }

  @Test func oversizedContentRefusesAtGateTime() throws {
    // given
    let huge = String(repeating: "a", count: FileWriteTool.maxContentBytes + 1)

    // when / then
    guard
      case .refused(let reason) = makeTool(root: try makeWorkspace()).canonicalTarget(
        arguments: args(path: "big.txt", content: huge)
      )
    else {
      Issue.record("expected the size cap to refuse")
      return
    }
    #expect(reason.contains("cap"))
  }

  @Test func executeWritesAtomicallyAndCreatesParents() async throws {
    // given
    let root = try makeWorkspace()
    let tool = makeTool(root: root)
    let arguments = args(path: "a/b/c.txt", content: "nested")
    guard case .resolved(let target) = tool.canonicalTarget(arguments: arguments) else {
      Issue.record("resolution failed")
      return
    }

    // when
    let payload = await tool.execute(arguments: arguments, canonicalTarget: target)

    // then
    #expect(payload.status == .ok)
    #expect(payload.content.contains("created"))
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "nested")
  }

  @Test func executeOverwriteReplacesContentAndSaysSo() async throws {
    // given
    let root = try makeWorkspace()
    try Data("old".utf8).write(to: root.appendingPathComponent("plan.md"))
    let tool = makeTool(root: root)
    let arguments = args(path: "plan.md", content: "new", overwrite: true)
    guard case .resolved(let target) = tool.canonicalTarget(arguments: arguments) else {
      Issue.record("resolution failed")
      return
    }

    // when
    let payload = await tool.execute(arguments: arguments, canonicalTarget: target)

    // then
    #expect(payload.status == .ok)
    #expect(payload.content.contains("overwritten"))
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "new")
  }

  @Test func crashBetweenTempWriteAndRenameLeavesTheOriginalIntact() throws {
    // given — an original file, and the staged-but-not-committed state a crash would leave.
    // The target is built on the CANONICAL root (macOS: /var → /private/var), matching the only
    // form stage/commit ever receive in production — the gate's canonical resolution.
    let root = try makeWorkspace()
    let canonicalRoot = try #require(WorkspacePathContainment.canonicalPath(root.path))
    let target = canonicalRoot + "/plan.md"
    try Data("original".utf8).write(to: URL(fileURLWithPath: target))

    // when — step 1 only (the crash window of §6.3/§6.6)
    let tempPath = try FileWriteTool.stageTemporary(
      content: Data("replacement".utf8),
      target: target
    )

    // then — the original is untouched and the temp lives INSIDE the workspace (same volume)
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "original")
    #expect(WorkspacePathContainment.isContained(target: tempPath, root: canonicalRoot))

    // when — step 2 commits
    try FileWriteTool.commitRename(tempPath: tempPath, target: target)

    // then — atomic replacement, temp gone
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "replacement")
    #expect(FileManager.default.fileExists(atPath: tempPath) == false)
  }

  @Test func createApprovedWriteFailsClosedWhenTheTargetAppearsAfterApproval() async throws {
    // given — gate time: plan.md does not exist, so the approval binds to a CREATE
    let root = try makeWorkspace()
    let tool = makeTool(root: root)
    let arguments = args(path: "plan.md", content: "late")
    guard case .resolved(let target) = tool.canonicalTarget(arguments: arguments) else {
      Issue.record("resolution failed")
      return
    }

    // when — the file appears while the approval is pending, then the recorded args execute
    try Data("raced in".utf8).write(to: URL(fileURLWithPath: target))
    let payload = await tool.execute(arguments: arguments, canonicalTarget: target)

    // then — fail closed (§10.2): the owner approved a CREATE, never a silent overwrite
    #expect(payload.status == .error)
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "raced in")
  }

  @Test func executeFailsClosedWhenAPathComponentIsRetargetedAfterApproval() async throws {
    // given — gate time: sub/ is a real directory inside the workspace
    let root = try makeWorkspace()
    try FileManager.default.createDirectory(
      atPath: root.path + "/sub",
      withIntermediateDirectories: true
    )
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-filewrite-outside-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    let tool = makeTool(root: root)
    let arguments = args(path: "sub/new.txt", content: "drift")
    guard case .resolved(let target) = tool.canonicalTarget(arguments: arguments) else {
      Issue.record("resolution failed")
      return
    }

    // when — sub/ is swapped for a symlink pointing OUTSIDE the workspace, then execute runs
    try FileManager.default.removeItem(atPath: root.path + "/sub")
    try FileManager.default.createSymbolicLink(
      atPath: root.path + "/sub",
      withDestinationPath: outside
    )
    let payload = await tool.execute(arguments: arguments, canonicalTarget: target)

    // then — the re-resolution drifts from the approved target: nothing written anywhere
    #expect(payload.status == .error)
    #expect(FileManager.default.fileExists(atPath: outside + "/new.txt") == false)
    #expect(FileManager.default.fileExists(atPath: target) == false)
  }

  @Test func presentationDistinguishesCreateFromOverwriteAndRedactsSecrets() throws {
    // given
    let root = try makeWorkspace()
    try Data("old".utf8).write(to: root.appendingPathComponent("plan.md"))
    let tool = makeTool(root: root, secrets: ["sk-verysecretvalue1"])
    let overwriteArgs = args(path: "plan.md", content: "key sk-verysecretvalue1", overwrite: true)
    guard case .resolved(let target) = tool.canonicalTarget(arguments: overwriteArgs) else {
      Issue.record("resolution failed")
      return
    }

    // when
    let overwritePresentation = tool.approvalPresentation(
      arguments: overwriteArgs,
      canonicalTarget: target
    )
    let createPresentation = tool.approvalPresentation(
      arguments: args(path: "fresh.md", content: "hi"),
      canonicalTarget: root.path + "/fresh.md"
    )

    // then — §5.4 blast radius (create vs overwrite + byte count) + secret-redacted preview
    #expect(overwritePresentation.blastRadius.hasPrefix("overwrite"))
    #expect(overwritePresentation.blastRadius.contains("B"))
    #expect(overwritePresentation.contentPreview?.contains("sk-verysecretvalue1") == false)
    #expect(createPresentation.blastRadius.hasPrefix("create"))
    #expect(createPresentation.warnings.isEmpty)
  }

  @Test func byteCountFormatsForOwners() {
    // given / when / then
    #expect(ByteCount.text(340) == "340 B")
    #expect(ByteCount.text(1229) == "1.2 KB")
  }
}
