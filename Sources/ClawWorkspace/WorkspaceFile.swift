import Foundation

/// The fixed workspace files load by name (spec §6). Dated daily logs
/// (`memory/YYYY-MM-DD.md`) have dynamic names and load via `WorkspaceReading.loadDailyLog`, so they
/// are deliberately not cases here. `HEARTBEAT.md` is read ONLY by the scheduler's heartbeat
/// branch (Inc 4 spec §12) — `ContextBuilder` loads files by explicit case, never `allCases`,
/// so the checklist never leaks into ordinary turn assembly.
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
