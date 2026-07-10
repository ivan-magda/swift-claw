import Foundation

/// A non-fatal diagnostic from a workspace scan, for the consuming layer to log.
/// `ClawWorkspace` is pure I/O and owns no logger.
public enum WorkspaceWarning: Sendable, Equatable {
  /// `skills/<skill>/SKILL.md` exists but is unusable (no `---` fence, malformed YAML, or missing
  /// `name`/`description`).
  case invalidSkillManifest(skill: String)

  /// `skills/` exists but could not be listed (a context-read failure, distinct from a missing
  /// `skills/` directory, which is normal and silent).
  case unreadableSkillsDirectory
}

/// The result of scanning `skills/`: the valid descriptors plus any skip warnings.
public struct SkillScanResult: Sendable, Equatable {
  public let descriptors: [SkillDescriptor]
  public let warnings: [WorkspaceWarning]

  public init(descriptors: [SkillDescriptor], warnings: [WorkspaceWarning]) {
    self.descriptors = descriptors
    self.warnings = warnings
  }
}
