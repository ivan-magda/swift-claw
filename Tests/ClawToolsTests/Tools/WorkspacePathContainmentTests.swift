import Foundation
import Testing

@testable import ClawTools

@Suite struct WorkspacePathContainmentTests {
  private struct Sandbox {
    let root: String
    let outside: String
  }

  /// A unique real directory pair per test: `<tmp>/…/ws` (the workspace) and a sibling escape
  /// target. macOS `/tmp` is itself a symlink, so expectations are always built from the
  /// helper's own canonical form of `root`, never from the raw temp path.
  private func makeSandbox() throws -> Sandbox {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-containment-\(UUID().uuidString)").path
    let root = base + "/ws"
    let outside = base + "/outside"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    return Sandbox(root: root, outside: outside)
  }

  private func write(_ text: String, to path: String) throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }

  private func expectRefused(
    _ resolution: WorkspacePathContainment.Resolution,
    _ label: String
  ) {
    guard case .refused = resolution else {
      Issue.record("\(label): expected .refused, got \(resolution)")
      return
    }
  }

  // MARK: - resolveExisting (behavior-preserving extraction)

  @Test func relativePathInsideTheWorkspaceResolves() throws {
    // given
    let sandbox = try makeSandbox()
    try write("hello", to: sandbox.root + "/notes/a.md")
    let canonicalRoot = try #require(WorkspacePathContainment.canonicalPath(sandbox.root))

    // when
    let resolution = WorkspacePathContainment.resolveExisting(
      path: "notes/a.md",
      root: sandbox.root
    )

    // then
    #expect(resolution == .resolved(canonicalRoot + "/notes/a.md"))
  }

  @Test func absolutePathIsRefused() throws {
    // given
    let sandbox = try makeSandbox()

    // when / then
    expectRefused(
      WorkspacePathContainment.resolveExisting(path: "/etc/hosts", root: sandbox.root),
      "existing"
    )
    expectRefused(
      WorkspacePathContainment.resolveForCreation(path: "/etc/hosts", root: sandbox.root),
      "creation"
    )
  }

  @Test func dotDotThatResolvesInsideStillReadsForExistingPaths() throws {
    // given — realpath fully resolves `..`; the READ path keeps FileReadTool's current semantics
    let sandbox = try makeSandbox()
    try write("x", to: sandbox.root + "/sub/keep.txt")
    try write("y", to: sandbox.root + "/inside.txt")
    let canonicalRoot = try #require(WorkspacePathContainment.canonicalPath(sandbox.root))

    // when
    let resolution = WorkspacePathContainment.resolveExisting(
      path: "sub/../inside.txt",
      root: sandbox.root
    )

    // then
    #expect(resolution == .resolved(canonicalRoot + "/inside.txt"))
  }

  @Test func dotDotEscapeIsRefusedForExistingPaths() throws {
    // given
    let sandbox = try makeSandbox()
    try write("secret", to: sandbox.outside + "/loot.txt")

    // when / then — resolves to a real file OUTSIDE the root → containment refuses
    expectRefused(
      WorkspacePathContainment.resolveExisting(path: "../outside/loot.txt", root: sandbox.root),
      "dot-dot escape"
    )
  }

  @Test func symlinkedDirectoryEscapeIsRefused() throws {
    // given — a link INSIDE the workspace pointing at a directory OUTSIDE it
    let sandbox = try makeSandbox()
    try write("secret", to: sandbox.outside + "/leak.txt")
    try FileManager.default.createSymbolicLink(
      atPath: sandbox.root + "/link",
      withDestinationPath: sandbox.outside
    )

    // when / then — both modes must refuse (the link resolves outside)
    expectRefused(
      WorkspacePathContainment.resolveExisting(path: "link/leak.txt", root: sandbox.root),
      "existing via symlinked dir"
    )
    expectRefused(
      WorkspacePathContainment.resolveForCreation(path: "link/new.txt", root: sandbox.root),
      "creation via symlinked dir"
    )
  }

  @Test func symlinkLeafEscapeIsRefused() throws {
    // given — the LEAF itself is a symlink to an outside file
    let sandbox = try makeSandbox()
    try write("secret", to: sandbox.outside + "/target.txt")
    try FileManager.default.createSymbolicLink(
      atPath: sandbox.root + "/alias.txt",
      withDestinationPath: sandbox.outside + "/target.txt"
    )

    // when / then — reading OR overwriting through it would act outside the workspace
    expectRefused(
      WorkspacePathContainment.resolveExisting(path: "alias.txt", root: sandbox.root),
      "existing symlink leaf"
    )
    expectRefused(
      WorkspacePathContainment.resolveForCreation(path: "alias.txt", root: sandbox.root),
      "creation symlink leaf"
    )
  }

  // MARK: - resolveForCreation

  @Test func nestedToBeCreatedPathResolvesUnderTheDeepestExistingAncestor() throws {
    // given — only `sub/` exists; `a/b.txt` below it is new
    let sandbox = try makeSandbox()
    try FileManager.default.createDirectory(
      atPath: sandbox.root + "/sub",
      withIntermediateDirectories: true
    )
    let canonicalRoot = try #require(WorkspacePathContainment.canonicalPath(sandbox.root))

    // when
    let resolution = WorkspacePathContainment.resolveForCreation(
      path: "sub/a/b.txt",
      root: sandbox.root
    )

    // then
    #expect(resolution == .resolved(canonicalRoot + "/sub/a/b.txt"))
  }

  @Test func dotDotComponentsAreRefusedForCreation() throws {
    // given — new components cannot be realpath-resolved, so `..` is refused outright
    let sandbox = try makeSandbox()
    try FileManager.default.createDirectory(
      atPath: sandbox.root + "/sub",
      withIntermediateDirectories: true
    )

    // when / then — even a dot-dot that would lexically stay inside
    expectRefused(
      WorkspacePathContainment.resolveForCreation(path: "sub/../fresh.txt", root: sandbox.root),
      "lexical dot-dot"
    )
    expectRefused(
      WorkspacePathContainment.resolveForCreation(path: "../escape.txt", root: sandbox.root),
      "escaping dot-dot"
    )
  }

  @Test func danglingSymlinkLeafIsRefusedForCreation() throws {
    // given — a broken symlink: realpath fails, but creating "through" it would follow the link
    let sandbox = try makeSandbox()
    try FileManager.default.createSymbolicLink(
      atPath: sandbox.root + "/dangling.txt",
      withDestinationPath: sandbox.outside + "/not-yet-there.txt"
    )

    // when / then
    expectRefused(
      WorkspacePathContainment.resolveForCreation(path: "dangling.txt", root: sandbox.root),
      "dangling symlink leaf"
    )
  }

  @Test func creationThroughAnInsideSymlinkedDirectoryResolvesToItsRealPath() throws {
    // given — a symlink to a directory INSIDE the workspace is legitimate; the resolved form is
    // what the approval binds to (§5.4: fully-resolved canonical target)
    let sandbox = try makeSandbox()
    try FileManager.default.createDirectory(
      atPath: sandbox.root + "/real",
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: sandbox.root + "/shortcut",
      withDestinationPath: sandbox.root + "/real"
    )
    let canonicalRoot = try #require(WorkspacePathContainment.canonicalPath(sandbox.root))

    // when
    let resolution = WorkspacePathContainment.resolveForCreation(
      path: "shortcut/new.txt",
      root: sandbox.root
    )

    // then
    #expect(resolution == .resolved(canonicalRoot + "/real/new.txt"))
  }

  @Test func fullyExistingPathResolvesForCreationToo() throws {
    // given — the overwrite case: every component exists
    let sandbox = try makeSandbox()
    try write("old", to: sandbox.root + "/plan.md")
    let canonicalRoot = try #require(WorkspacePathContainment.canonicalPath(sandbox.root))

    // when
    let resolution = WorkspacePathContainment.resolveForCreation(
      path: "plan.md",
      root: sandbox.root
    )

    // then
    #expect(resolution == .resolved(canonicalRoot + "/plan.md"))
  }

  // MARK: - Prefix collision

  @Test func prefixCollisionSiblingIsNotContained() throws {
    // given — /…/wsx shares the string prefix of /…/ws but is a SIBLING directory
    let sandbox = try makeSandbox()
    let sibling = sandbox.root + "x"
    try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: sandbox.root + "/side",
      withDestinationPath: sibling
    )

    // when / then — component-wise prefix: /a/bc is NOT inside /a/b (unit + integration)
    #expect(WorkspacePathContainment.isContained(target: "/a/bc", root: "/a/b") == false)
    #expect(WorkspacePathContainment.isContained(target: "/a/b/c", root: "/a/b"))
    #expect(WorkspacePathContainment.isContained(target: "/a/b", root: "/a/b"))
    expectRefused(
      WorkspacePathContainment.resolveForCreation(path: "side/new.txt", root: sandbox.root),
      "prefix-collision sibling"
    )
    expectRefused(
      WorkspacePathContainment.resolveExisting(path: "side", root: sandbox.root),
      "prefix-collision sibling (existing)"
    )
  }
}
