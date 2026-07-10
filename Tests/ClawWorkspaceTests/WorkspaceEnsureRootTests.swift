import Foundation
import Testing

@testable import ClawWorkspace

@Suite struct WorkspaceEnsureRootTests {
  @Test func ensureRootExistsCreatesAMissingWorkspaceDirectory() throws {
    // given — a workspace root under a not-yet-created parent, mirroring a fresh install where
    // the state root exists but its `workspace/` sandbox does not
    let parent = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("workspace", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: root.path) == false)

    // when
    try FileSystemWorkspace(root: root).ensureRootExists()

    // then
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }

  @Test func ensureRootExistsIsIdempotentAndPreservesExistingContent() throws {
    // given — the sandbox already exists with a file the owner wrote earlier
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(atRelativePath: "notes/keep.md", content: "keep", under: root)

    // when — re-ensuring at the next boot must neither throw nor disturb existing content
    try FileSystemWorkspace(root: root).ensureRootExists()

    // then
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/keep.md").path)
    )
  }

  @Test func ensureRootExistsCreatesAnOwnerOnlyDirectory() throws {
    // given
    let parent = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("workspace", isDirectory: true)

    // when
    try FileSystemWorkspace(root: root).ensureRootExists()

    // then — owner-only (0700), matching the state root the sandbox lives under
    let permissions =
      try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
    #expect(permissions == 0o700)
  }
}
