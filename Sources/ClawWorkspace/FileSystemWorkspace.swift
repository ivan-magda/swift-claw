import ClawCore
import Foundation
import Yams

public struct FileSystemWorkspace: WorkspaceReading {
  private static let maxNameGraphemes = 64
  /// The spec allows 1024; the index has to scale with skill count, not with one author's prose.
  private static let maxDescriptionGraphemes = 300

  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public func ensureRootExists() throws {
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  public func load(file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
    loadFile(at: root.appendingPathComponent(file.relativePath), maxGraphemes: maxGraphemes)
  }

  public func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile {
    guard Self.isDayStem(day) else {
      return .missing
    }

    let fileURL =
      root
      .appendingPathComponent("memory", isDirectory: true)
      .appendingPathComponent("\(day).md")

    return loadFile(at: fileURL, maxGraphemes: maxGraphemes)
  }

  public func scanSkills() -> SkillScanResult {
    let fileManager = FileManager.default
    let skillsRoot = root.appendingPathComponent(
      WorkspaceSkills.directoryName,
      isDirectory: true
    )

    var skillsIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: skillsRoot.path, isDirectory: &skillsIsDirectory) else {
      return SkillScanResult(descriptors: [], warnings: [])
    }
    guard skillsIsDirectory.boolValue else {
      return SkillScanResult(descriptors: [], warnings: [.unreadableSkillsDirectory])
    }
    // Each skill is contained against `skills/`, so a symlinked `skills/` would move the boundary
    // it is checked against and index manifests from anywhere on disk.
    guard let containmentRoot = Self.containedSkillsRoot(skillsRoot, under: root) else {
      return SkillScanResult(descriptors: [], warnings: [.skillsDirectoryOutsideWorkspace])
    }

    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: containmentRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      // skills/ exists but cannot be listed: a context-read failure, not a missing directory.
      return SkillScanResult(descriptors: [], warnings: [.unreadableSkillsDirectory])
    }

    var descriptors: [SkillDescriptor] = []
    var warnings: [WorkspaceWarning] = []

    for subdir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      switch Self.entry(at: subdir, under: containmentRoot) {
      case .notASkill:
        continue
      case .rejected(let warning):
        warnings.append(warning)
      case .usable(let descriptor):
        descriptors.append(descriptor)
      }
    }

    let reconciled = Self.withoutCollidingNames(descriptors)
    return SkillScanResult(
      descriptors: reconciled.descriptors,
      warnings: warnings + reconciled.warnings
    )
  }

  /// What one `skills/` subdirectory turns out to be.
  enum SkillEntry {
    /// No `SKILL.md` at all — an ordinary subdirectory, not an authoring fault.
    case notASkill
    case rejected(WorkspaceWarning)
    case usable(SkillDescriptor)
  }

  /// The canonical `skills/` directory, or nil when it resolves outside the canonical workspace
  /// root — which is what makes it a sound containment anchor for the skills beneath it.
  static func containedSkillsRoot(_ skillsRoot: URL, under root: URL) -> URL? {
    guard
      let canonicalRoot = WorkspacePathContainment.canonicalPath(root.path),
      let canonicalSkillsRoot = WorkspacePathContainment.canonicalPath(skillsRoot.path),
      WorkspacePathContainment.isContained(target: canonicalSkillsRoot, root: canonicalRoot)
    else {
      return nil
    }
    return URL(fileURLWithPath: canonicalSkillsRoot, isDirectory: true)
  }

  /// Settles one subdirectory's identity: containment first, then the manifest's own claims.
  static func entry(at subdir: URL, under skillsRoot: URL) -> SkillEntry {
    let manifestURL = subdir.appendingPathComponent(WorkspaceSkills.manifestName)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      return .notASkill
    }

    let directoryName = subdir.lastPathComponent
    // The loader resolves this same relative path through containment before serving a body, so a
    // manifest that lives outside the workspace is dropped here rather than indexed as a skill
    // every load would refuse. The vetted path is then what gets read.
    let manifestPath: String
    switch WorkspacePathContainment.resolveExisting(
      path: "\(directoryName)/\(WorkspaceSkills.manifestName)",
      root: skillsRoot.path
    ) {
    case .refused:
      return .rejected(.escapingSkillDirectory(directory: directoryName))
    case .resolved(let resolved):
      manifestPath = resolved
    }

    // An unreadable manifest folds to "" → empty frontmatter → the same invalid-manifest warning.
    let manifestText = (try? String(contentsOfFile: manifestPath, encoding: .utf8)) ?? ""
    let frontmatter = Self.frontmatter(in: manifestText)
    let description = Self.singleLine(frontmatter["description"] ?? "")
    guard
      let name = frontmatter["name"], name.isEmpty == false,
      description.isEmpty == false
    else {
      return .rejected(.invalidSkillManifest(skill: directoryName))
    }
    guard Self.isSkillIdentifier(name) else {
      return .rejected(.invalidSkillName(directory: directoryName, name: Self.bounded(name)))
    }
    guard name == directoryName else {
      return .rejected(.skillNameDirectoryMismatch(directory: directoryName, name: name))
    }

    return .usable(
      SkillDescriptor(
        name: name,
        description: TextTruncation.cap(description, maxGraphemes: Self.maxDescriptionGraphemes),
        directory: subdir
      )
    )
  }

  /// Drops every claimant of a duplicated name: two directories asserting one identity leave no
  /// principled winner, and shadowing one silently is exactly what the loader must never do.
  static func withoutCollidingNames(
    _ descriptors: [SkillDescriptor]
  ) -> (descriptors: [SkillDescriptor], warnings: [WorkspaceWarning]) {
    var directoriesByName: [String: [String]] = [:]
    for descriptor in descriptors {
      directoriesByName[descriptor.name, default: []].append(descriptor.directory.lastPathComponent)
    }

    let collidingNames = Set(directoriesByName.filter { $0.value.count > 1 }.keys)
    guard collidingNames.isEmpty == false else {
      return (descriptors, [])
    }

    let warnings = collidingNames.sorted().map { name in
      WorkspaceWarning.duplicateSkillName(name: name, directories: directoriesByName[name] ?? [])
    }
    return (descriptors.filter { collidingNames.contains($0.name) == false }, warnings)
  }

  /// The index prints one line per skill and counts those lines in its drop marker, so a YAML
  /// block scalar or a quoted newline must not let one description occupy several of them.
  private static func singleLine(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// A rejected name is arbitrary YAML — a block scalar carries newlines and has no length bound —
  /// and it rides a warning into the owner's chat and the log verbatim, once per turn until the
  /// manifest is fixed. Bind it to the shape a valid name could have had.
  private static func bounded(_ name: String) -> String {
    TextTruncation.cap(singleLine(name), maxGraphemes: maxNameGraphemes)
  }

  /// The agentskills.io identifier shape: `^[a-z0-9]+(-[a-z0-9]+)*$`, 1–64 characters.
  private static func isSkillIdentifier(_ name: String) -> Bool {
    guard (1...maxNameGraphemes).contains(name.count) else {
      return false
    }

    let segments = name.split(separator: "-", omittingEmptySubsequences: false)
    return segments.allSatisfy { segment in
      segment.isEmpty == false
        && segment.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
  }

  /// Extracts the leading `---`-fenced YAML block, keeping only string-valued keys. Empty when
  /// there is no opening/closing fence or the block is not a parseable string map.
  private static func frontmatter(in text: String) -> [String: String] {
    guard let document = FrontmatterFence.split(text) else {
      return [:]
    }

    guard let parsed = (try? Yams.load(yaml: document.frontmatter)) as? [String: Any] else {
      return [:]
    }

    var result: [String: String] = [:]
    for (key, value) in parsed {
      if let stringValue = value as? String {
        result[key] = stringValue
      }
    }

    return result
  }

  /// True only for a `YYYY-MM-DD` stem (four digits, two, two). Rejects path separators and `..`.
  private static func isDayStem(_ day: String) -> Bool {
    let parts = day.split(separator: "-", omittingEmptySubsequences: false)
    let expectedLengths = [4, 2, 2]
    guard parts.count == expectedLengths.count else {
      return false
    }

    for (part, length) in zip(parts, expectedLengths) {
      guard part.count == length, part.allSatisfy({ ("0"..."9").contains($0) }) else {
        return false
      }
    }

    return true
  }

  /// Shared read + outcome classification for any single file path.
  func loadFile(at fileURL: URL, maxGraphemes: Int?) -> LoadedFile {
    let fileManager = FileManager.default

    guard fileManager.fileExists(atPath: fileURL.path) else {
      return .missing
    }

    guard
      let rawData = try? Data(contentsOf: fileURL),
      let text = String(data: rawData, encoding: .utf8)
    else {
      return LoadedFile(outcome: .unreadable, text: "", graphemeCount: 0)
    }

    let graphemeCount = text.count
    if let cap = maxGraphemes, graphemeCount > cap {
      return LoadedFile(outcome: .overCap, text: "", graphemeCount: graphemeCount)
    }

    return LoadedFile(outcome: .present, text: text, graphemeCount: graphemeCount)
  }
}
