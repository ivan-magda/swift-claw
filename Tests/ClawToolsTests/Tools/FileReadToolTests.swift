import ClawCore
import Foundation
import Testing

@testable import ClawTools

@Suite struct FileReadToolTests {
  /// A real temp workspace with a sibling "outside" directory for escape tests.
  private struct Fixture {
    let root: URL
    let outside: URL
    let tool: FileReadTool
  }

  private func makeFixture() throws -> Fixture {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-fileread-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("workspace", isDirectory: true)
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let tool = FileReadTool(
      workspaceRoot: root,
      redactor: SecretRedactor(secretValues: ["tok-secret-1"])
    )
    return Fixture(root: root, outside: outside, tool: tool)
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url)
  }

  private func execute(_ tool: FileReadTool, path: String) async -> ToolPayload {
    await tool.execute(arguments: .object(["path": .string(path)]))
  }

  @Test func readsARelativeFileAndSetsUntrusted() async throws {
    // given
    let fixture = try makeFixture()
    try write("project status: green", to: fixture.root.appendingPathComponent("notes/status.md"))

    // when
    let payload = await execute(fixture.tool, path: "notes/status.md")

    // then
    #expect(payload.status == .ok)
    #expect(payload.content == "project status: green")
    #expect(payload.ingestedUntrusted)
    #expect(payload.readPrivateData == false)
  }

  @Test func refusesAbsoluteAndEmptyPaths() async throws {
    // given
    let fixture = try makeFixture()

    // when / then
    #expect((await execute(fixture.tool, path: "/etc/hosts")).status == .error)
    #expect((await execute(fixture.tool, path: "")).status == .error)
  }

  @Test func dotDotTraversalFailsContainment() async throws {
    // given — a real file outside the workspace (FR-T4 tested invariant)
    let fixture = try makeFixture()
    try write("outside secret", to: fixture.outside.appendingPathComponent("target.md"))

    // when
    let payload = await execute(fixture.tool, path: "../outside/target.md")

    // then
    #expect(payload.status == .error)
    #expect(payload.content.contains("outside secret") == false)
    #expect(payload.ingestedUntrusted == false)
  }

  @Test func outPointingSymlinkFailsContainment() async throws {
    // given — a symlink INSIDE the workspace pointing OUT (FR-T4: the final target is asserted)
    let fixture = try makeFixture()
    let target = fixture.outside.appendingPathComponent("real.md")
    try write("outside via link", to: target)
    let link = fixture.root.appendingPathComponent("innocent.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    // when
    let payload = await execute(fixture.tool, path: "innocent.md")

    // then
    #expect(payload.status == .error)
    #expect(payload.content.contains("outside via link") == false)
  }

  @Test func refusesBinaryContent() async throws {
    // given
    let fixture = try makeFixture()
    let url = fixture.root.appendingPathComponent("blob.bin")
    try Data([0xFF, 0xFE, 0x00, 0x01, 0x80]).write(to: url)

    // when
    let payload = await execute(fixture.tool, path: "blob.bin")

    // then
    #expect(payload.status == .error)
  }

  @Test func missingFileIsAFriendlyError() async throws {
    // given
    let fixture = try makeFixture()

    // when
    let payload = await execute(fixture.tool, path: "nope.md")

    // then
    #expect(payload.status == .error)
    #expect(payload.ingestedUntrusted == false)
  }

  @Test func redactsExactSecretValuesFromContent() async throws {
    // given
    let fixture = try makeFixture()
    try write("the token is tok-secret-1 ok", to: fixture.root.appendingPathComponent("leak.md"))

    // when
    let payload = await execute(fixture.tool, path: "leak.md")

    // then
    #expect(payload.content == "the token is [REDACTED:secret-value] ok")
  }

  @Test func memoryFileReadSetsThePrivateDataFlag() async throws {
    // given (rev.1 H1 — the run-local private-data signal)
    let fixture = try makeFixture()
    try write("private memory", to: fixture.root.appendingPathComponent("MEMORY.md"))
    try write("user profile", to: fixture.root.appendingPathComponent("USER.md"))
    try write("plain", to: fixture.root.appendingPathComponent("OTHER.md"))
    // notes/ must exist on disk so realpath can walk the `notes/../MEMORY.md` route — `..` is
    // resolved against a real directory, not collapsed lexically, so without it realpath fails.
    try write("keep", to: fixture.root.appendingPathComponent("notes/keep.md"))

    // when / then — matched on the CANONICAL resolved path, so a dotted route counts too
    #expect((await execute(fixture.tool, path: "MEMORY.md")).readPrivateData)
    #expect((await execute(fixture.tool, path: "USER.md")).readPrivateData)
    #expect((await execute(fixture.tool, path: "notes/../MEMORY.md")).readPrivateData)
    #expect((await execute(fixture.tool, path: "OTHER.md")).readPrivateData == false)
  }
}
