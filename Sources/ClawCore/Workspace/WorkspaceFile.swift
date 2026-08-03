import Foundation

/// The fixed workspace files load by name. Dated daily logs (`memory/YYYY-MM-DD.md`) have
/// dynamic names and load via `WorkspaceReading.loadDailyLog`, so they are deliberately not
/// cases here. `HEARTBEAT.md` is read ONLY by the scheduler's heartbeat branch —
/// `ContextBuilder` loads files by explicit case, never `allCases`, so the checklist never
/// leaks into ordinary turn assembly.
public enum WorkspaceFile: String, Sendable, Equatable, CaseIterable {
  case soul = "SOUL.md"
  case agents = "AGENTS.md"
  case tools = "TOOLS.md"
  case user = "USER.md"
  case memory = "MEMORY.md"
  case heartbeat = "HEARTBEAT.md"

  /// Path relative to the workspace root.
  public var relativePath: String { rawValue }
}

extension WorkspaceFile {
  /// The prompt files that hold the owner's private data. A tool that reads one flags the turn as
  /// having touched private data, which is one leg of the exfiltration trifecta.
  public static let privateDataFiles: [WorkspaceFile] = [.user, .memory]

  /// True when the file at `canonicalPath` steers a later turn — the fixed prompt files, plus any
  /// `SKILL.md`, whose body `skill_load` serves back as owner-authored guidance to follow. A write
  /// to one of these is flagged to the owner behind the privileged-file banner, so the match is by
  /// basename: a skill manifest is named by its directory, and a prompt file the owner keeps
  /// elsewhere is no less privileged for it.
  public static func isPromptPrivileged(basename: String) -> Bool {
    basename == WorkspaceSkills.manifestName
      || allCases.contains { file in file.relativePath == basename }
  }

  /// True when `canonicalPath` is a private-data prompt file sitting directly at the canonical
  /// workspace root. Both inputs must already be canonical (symlinks and `..` resolved); the match
  /// is exact full-path equality against the root-anchored name, never a prefix test.
  public static func isPrivateData(canonicalPath: String, canonicalRoot: String) -> Bool {
    privateDataFiles.contains { file in
      canonicalPath == canonicalRoot + "/" + file.relativePath
    }
  }
}
