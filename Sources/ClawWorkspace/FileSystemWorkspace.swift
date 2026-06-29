import ClawCore
import Foundation

/// Pure workspace file I/O and parsing (spec §3, §6). No budget, LLM, or config knowledge: per-file
/// grapheme caps arrive as a parameter and the caller decides how to react to each `LoadedFile`.
public protocol WorkspaceReading: Sendable {
  /// Loads a fixed workspace file in the grapheme domain. A missing file returns `.missing`, an
  /// undecodable file `.unreadable`, an over-cap file `.overCap` (no consumable text), and never
  /// throws. `maxGraphemes` nil means no cap.
  func load(_ file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile
}

public struct FileSystemWorkspace: WorkspaceReading {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public func load(_ file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
    loadFile(at: root.appendingPathComponent(file.relativePath), maxGraphemes: maxGraphemes)
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
