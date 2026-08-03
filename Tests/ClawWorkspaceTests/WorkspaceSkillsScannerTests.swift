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

  @Test(arguments: ["a", "data-export-helper", String(repeating: "s", count: 64)])
  func acceptsNameAtTheEdgesOfTheIdentifierShape(name: String) throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = "---\nname: \(name)\ndescription: Edge name.\n---\nbody"
    try writeSkill(named: name, manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then
    #expect(result.warnings.isEmpty)
    #expect(result.descriptors.map(\.name) == [name])
  }

  @Test func longDescriptionIsCappedAtScanTime() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = "---\nname: verbose\ndescription: \(String(repeating: "x", count: 400))\n---\n"
    try writeSkill(named: "verbose", manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then - the index must scale with skill count, not with one author's verbosity.
    #expect(result.warnings.isEmpty)
    let descriptor = try #require(result.descriptors.first)
    #expect(descriptor.description.count == 300)
    #expect(descriptor.description.hasSuffix(TextTruncation.marker))
  }

  @Test func descriptionAtTheCapIsKeptWhole() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let description = String(repeating: "x", count: 300)
    let manifest = "---\nname: exact\ndescription: \(description)\n---\n"
    try writeSkill(named: "exact", manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then
    #expect(result.descriptors.first?.description == description)
  }

  @Test func multiLineDescriptionCollapsesToOneIndexLine() throws {
    // given - a YAML block scalar the index would otherwise print across several lines
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = """
      ---
      name: verbose
      description: |
        First line.
        Second line.
      ---
      """
    try writeSkill(named: "verbose", manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then - one skill occupies exactly one line, so the drop marker's count stays true
    #expect(result.warnings.isEmpty)
    #expect(result.descriptors.first?.description == "First line. Second line.")
  }

  @Test func whitespaceOnlyDescriptionIsSkippedWithWarning() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = "---\nname: blank\ndescription: \"   \"\n---\n"
    try writeSkill(named: "blank", manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then - a description of nothing indexes as nothing, so it is an authoring fault
    #expect(result.descriptors.isEmpty)
    #expect(result.warnings == [.invalidSkillManifest(skill: "blank")])
  }

  @Test(
    arguments: [
      "Summarize",
      "sum--marize",
      "-summarize",
      "summarize-",
      String(repeating: "s", count: 65),
    ]
  )
  func manifestWithNameOutsideTheIdentifierShapeIsSkippedWithWarning(name: String) throws {
    // given - directory and name agree, so only the shape can reject the skill.
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = "---\nname: \(name)\ndescription: Bad identifier.\n---\n"
    try writeSkill(named: name, manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then - the warning quotes the rejected name back, bounded to what a valid one could be
    #expect(result.descriptors.isEmpty)
    #expect(
      result.warnings == [
        .invalidSkillName(directory: name, name: TextTruncation.cap(name, maxGraphemes: 64))
      ]
    )
  }

  @Test func aRejectedNameReachesTheOwnerAsOneBoundedLine() throws {
    // given - a block scalar name: unbounded and multi-line, and the notice it produces is
    // prepended to every reply until the manifest is fixed
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runaway = String(repeating: "A", count: 500)
    let manifest = """
      ---
      name: |
        \(runaway)
        second line
      description: An unbounded name.
      ---
      """
    try writeSkill(named: "runaway", manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then - one line, capped like a description, so no manifest can flood the owner or the log
    #expect(result.descriptors.isEmpty)
    #expect(
      result.warnings == [
        .invalidSkillName(
          directory: "runaway",
          name: TextTruncation.cap("\(runaway) second line", maxGraphemes: 64)
        )
      ]
    )
  }

  @Test func manifestNameDisagreeingWithDirectoryIsSkippedWithWarning() throws {
    // given
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = "---\nname: beta\ndescription: Mismatched identity.\n---\n"
    try writeSkill(named: "alpha", manifest: manifest, under: root)
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then - the loader resolves a name to a directory, so the two identities must agree.
    #expect(result.descriptors.isEmpty)
    #expect(result.warnings == [.skillNameDirectoryMismatch(directory: "alpha", name: "beta")])
  }

  @Test func collidingNamesDropEveryClaimantAndWarn() {
    // given - unreachable through one scan root once name == directory holds; guarded anyway.
    let skillsRoot = URL(fileURLWithPath: "/tmp/skills", isDirectory: true)
    let directory = { (name: String) in
      skillsRoot.appendingPathComponent(name, isDirectory: true)
    }
    let descriptors = [
      SkillDescriptor(name: "alpha", description: "One.", directory: directory("one")),
      SkillDescriptor(name: "beta", description: "Kept.", directory: directory("beta")),
      SkillDescriptor(name: "alpha", description: "Two.", directory: directory("two")),
    ]

    // when
    let reconciled = FileSystemWorkspace.withoutCollidingNames(descriptors)

    // then - silent shadowing is the bug class, so no claimant wins.
    #expect(reconciled.descriptors.map(\.name) == ["beta"])
    #expect(
      reconciled.warnings == [.duplicateSkillName(name: "alpha", directories: ["one", "two"])]
    )
  }

  @Test func aSkillDirectorySymlinkedOutsideTheWorkspaceIsDroppedWithAWarning() throws {
    // given - the outside directory holds a perfectly valid manifest; only its location disqualifies it.
    let root = try makeTemporaryRoot()
    let outside = try makeTemporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try writeFile(atRelativePath: "elsewhere/SKILL.md", content: Self.validManifest, under: outside)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("skills", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("skills/summarize"),
      withDestinationURL: outside.appendingPathComponent("elsewhere")
    )
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then - the loader refuses this body, so the index must not advertise it.
    #expect(result.descriptors.isEmpty)
    #expect(result.warnings == [.escapingSkillDirectory(directory: "summarize")])
  }

  @Test func aSkillDirectorySymlinkedWithinTheSkillsTreeStillScans() throws {
    // given - "store" holds no SKILL.md of its own, so it scans as an ordinary skipped subdirectory.
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeFile(
      atRelativePath: "skills/store/summarize/SKILL.md",
      content: Self.validManifest,
      under: root
    )
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("skills/summarize"),
      withDestinationURL: root.appendingPathComponent("skills/store/summarize")
    )
    let workspace = FileSystemWorkspace(root: root)

    // when
    let result = workspace.scanSkills()

    // then - containment is what disqualifies a link, not the link itself.
    #expect(result.descriptors.map(\.name) == ["summarize"])
    #expect(result.warnings.isEmpty)
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
