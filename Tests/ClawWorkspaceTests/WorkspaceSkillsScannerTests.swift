import ClawCore
import Foundation
import Testing

@testable import ClawWorkspace

@Suite struct WorkspaceSkillsScannerTests {
  private static let validManifest = """
    ---
    name: summarize
    description: Summarize owner-provided text.
    ---
    # Summarize

    Body content the index ignores.
    """

  @Test func missingSkillsDirectoryYieldsEmptyResult() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then
    #expect(result.descriptors.isEmpty)
    #expect(result.warnings.isEmpty)
  }

  @Test func unlistableSkillsDirectoryWarnsAndIsDistinctFromMissing() throws {
    // given - "skills" exists as a regular file, so listing it as a directory reliably fails.
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(atRelativePath: "skills", content: "not a directory", under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then - a failed listing warns (§12 log + omit), unlike a missing dir which is silent.
    #expect(result.descriptors.isEmpty)
    #expect(result.warnings == [.unreadableSkillsDirectory])
  }

  @Test func validManifestBecomesDescriptorWithNameDescriptionAndDirectory() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSkill(named: "summarize", manifest: Self.validManifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then
    #expect(result.warnings.isEmpty)
    let descriptor = try #require(result.descriptors.first)
    #expect(descriptor.name == "summarize")
    #expect(descriptor.description == "Summarize owner-provided text.")
    #expect(descriptor.directory.lastPathComponent == "summarize")
  }

  @Test func subdirectoryWithoutManifestIsSkippedSilently() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let emptySkillDir =
      root
      .appendingPathComponent("skills", isDirectory: true)
      .appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: emptySkillDir, withIntermediateDirectories: true)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then - a non-skill directory is normal, not a warning.
    #expect(result.descriptors.isEmpty)
    #expect(result.warnings.isEmpty)
  }

  @Test func manifestMissingDescriptionIsSkippedWithWarning() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = """
      ---
      name: partial
      ---
      body
      """
    try writeSkill(named: "partial", manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then
    #expect(result.descriptors.isEmpty)
    #expect(result.warnings == [.invalidSkillManifest(skill: "partial")])
  }

  @Test func manifestWithoutFrontmatterFenceIsSkippedWithWarning() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = "# Just a heading\n\nNo frontmatter here."
    try writeSkill(named: "nofence", manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then
    #expect(result.descriptors.isEmpty)
    #expect(result.warnings == [.invalidSkillManifest(skill: "nofence")])
  }

  @Test func malformedFrontmatterYamlIsSkippedWithWarning() throws {
    // given - an unterminated flow sequence makes the YAML block unparseable.
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = """
      ---
      name: [unterminated
      description: x
      ---
      body
      """
    try writeSkill(named: "broken", manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then
    #expect(result.descriptors.isEmpty)
    #expect(result.warnings == [.invalidSkillManifest(skill: "broken")])
  }

  @Test func extraFrontmatterKeysAreIgnored() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = """
      ---
      name: rich
      description: Rich skill.
      version: 3
      tags: [a, b]
      ---
      body
      """
    try writeSkill(named: "rich", manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then
    #expect(result.warnings.isEmpty)
    let descriptor = try #require(result.descriptors.first)
    #expect(descriptor.name == "rich")
    #expect(descriptor.description == "Rich skill.")
  }

  @Test func multipleSkillsAreReturnedInDirectoryNameOrder() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSkill(
      named: "bravo",
      manifest: "---\nname: bravo\ndescription: Second.\n---\n",
      under: root
    )
    try writeSkill(
      named: "alpha",
      manifest: "---\nname: alpha\ndescription: First.\n---\n",
      under: root
    )
    let workspace = FileSystemWorkspace(root: root)

    // when
    let names = workspace.scanSkills().descriptors.map(\.name)

    // then
    #expect(names == ["alpha", "bravo"])
  }
}
