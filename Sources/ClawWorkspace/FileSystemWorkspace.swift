import ClawCore
import Foundation
import Yams

/// Pure workspace file I/O and parsing (spec §3, §6). No budget, LLM, or config knowledge: per-file
/// grapheme caps arrive as a parameter and the caller decides how to react to each `LoadedFile`.
public protocol WorkspaceReading: Sendable {
  /// Loads a fixed workspace file in the grapheme domain. A missing file returns `.missing`, an
  /// undecodable file `.unreadable`, an over-cap file `.overCap` (no consumable text), and never
  /// throws. `maxGraphemes` nil means no cap.
  func load(_ file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile

  /// Loads a dated daily log `memory/<day>.md`, where `day` is a `YYYY-MM-DD` stem. A stem that is
  /// not `YYYY-MM-DD`, or a missing file, returns `.missing`. Same outcome rules as `load`.
  func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile

  /// Scans `skills/<name>/SKILL.md` and returns one `SkillDescriptor` per skill whose frontmatter
  /// has a non-empty `name` and `description`, plus a `WorkspaceWarning` for each present-but-unusable
  /// manifest. A missing `skills/` directory or a subdirectory with no `SKILL.md` is skipped without
  /// a warning; a `skills/` directory that exists but cannot be listed yields
  /// `.unreadableSkillsDirectory` (§12). Never a half-entry, never a crash. Descriptors are sorted by
  /// directory name.
  func scanSkills() -> SkillScanResult
}

public struct FileSystemWorkspace: WorkspaceReading {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public func load(_ file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
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

    guard fileManager.fileExists(atPath: skillsRoot.path) else {
      return SkillScanResult(descriptors: [], warnings: [])  // no skills/ dir: normal, silent
    }

    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: skillsRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      // skills/ exists but cannot be listed: a §12 context-read failure, not a missing directory.
      return SkillScanResult(descriptors: [], warnings: [.unreadableSkillsDirectory])
    }

    var descriptors: [SkillDescriptor] = []
    var warnings: [WorkspaceWarning] = []

    for subdir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let manifestURL = subdir.appendingPathComponent(Self.skillManifestName)

      guard fileManager.fileExists(atPath: manifestURL.path) else {
        continue  // not a skill directory: normal, no warning
      }

      guard
        let manifestText = try? String(contentsOf: manifestURL, encoding: .utf8),
        let frontmatter = Self.frontmatter(in: manifestText),
        let name = frontmatter["name"], name.isEmpty == false,
        let description = frontmatter["description"], description.isEmpty == false
      else {
        warnings.append(.invalidSkillManifest(skill: subdir.lastPathComponent))
        continue
      }

      descriptors.append(SkillDescriptor(name: name, description: description, directory: subdir))
    }

    return SkillScanResult(descriptors: descriptors, warnings: warnings)
  }

  private static let skillsDirectoryName = "skills"
  private static let skillManifestName = "SKILL.md"

  /// Extracts the leading `---`-fenced YAML block, keeping only string-valued keys. Returns nil when
  /// there is no opening/closing fence or the block is not a parseable string map.
  private static func frontmatter(in text: String) -> [String: String]? {
    let lines = text.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return nil
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
      return nil
    }

    let yaml = yamlLines.joined(separator: "\n")
    guard let parsed = (try? Yams.load(yaml: yaml)) as? [String: Any] else {
      return nil
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

    guard let rawData = try? Data(contentsOf: fileURL),
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
