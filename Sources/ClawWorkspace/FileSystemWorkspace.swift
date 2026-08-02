import ClawCore
import Foundation
import Yams

public struct FileSystemWorkspace: WorkspaceReading {
  private static let skillsDirectoryName = "skills"
  private static let skillManifestName = "SKILL.md"
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
    let skillsRoot = root.appendingPathComponent(Self.skillsDirectoryName, isDirectory: true)

    var skillsIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: skillsRoot.path, isDirectory: &skillsIsDirectory) else {
      return SkillScanResult(descriptors: [], warnings: [])
    }
    guard skillsIsDirectory.boolValue else {
      return SkillScanResult(descriptors: [], warnings: [.unreadableSkillsDirectory])
    }

    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: skillsRoot,
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
      let manifestURL = subdir.appendingPathComponent(Self.skillManifestName)

      guard fileManager.fileExists(atPath: manifestURL.path) else {
        continue  // not a skill directory: normal, no warning
      }

      // An unreadable manifest folds to "" → empty frontmatter → the same invalid-manifest warning.
      let manifestText = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
      let frontmatter = Self.frontmatter(in: manifestText)
      let directoryName = subdir.lastPathComponent
      guard
        let name = frontmatter["name"], name.isEmpty == false,
        let description = frontmatter["description"], description.isEmpty == false
      else {
        warnings.append(.invalidSkillManifest(skill: directoryName))
        continue
      }
      guard Self.isSkillIdentifier(name) else {
        warnings.append(.invalidSkillName(directory: directoryName, name: name))
        continue
      }
      guard name == directoryName else {
        warnings.append(.skillNameDirectoryMismatch(directory: directoryName, name: name))
        continue
      }

      descriptors.append(
        SkillDescriptor(
          name: name,
          description: TextTruncation.cap(description, maxGraphemes: Self.maxDescriptionGraphemes),
          directory: subdir
        )
      )
    }

    let reconciled = Self.withoutCollidingNames(descriptors)
    return SkillScanResult(
      descriptors: reconciled.descriptors,
      warnings: warnings + reconciled.warnings
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
    let lines = text.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return [:]
    }

    var yamlLines: [String] = []
    var didCloseFence = false
    for line in lines.dropFirst() {
      if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
        didCloseFence = true
        break
      }
      yamlLines.append(line)
    }

    guard didCloseFence else {
      return [:]
    }

    let yaml = yamlLines.joined(separator: "\n")
    guard let parsed = (try? Yams.load(yaml: yaml)) as? [String: Any] else {
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
