import ClawCore
import Foundation

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
