import Foundation

/// The fixed workspace files Increment 3a loads by name (spec §6). Dated daily logs
/// (`memory/YYYY-MM-DD.md`) have dynamic names and load via `WorkspaceReading.loadDailyLog`, so they
/// are deliberately not cases here. `HEARTBEAT.md` is out of 3a scope (Inc 4).
public enum WorkspaceFile: String, Sendable, Equatable, CaseIterable {
  case soul = "SOUL.md"
  case agents = "AGENTS.md"
  case tools = "TOOLS.md"
  case user = "USER.md"
  case memory = "MEMORY.md"

  /// Path relative to the workspace root.
  public var relativePath: String { rawValue }
}
