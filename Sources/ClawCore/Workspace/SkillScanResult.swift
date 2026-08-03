import Foundation

/// A non-fatal diagnostic from a workspace scan, for the consuming layer to log.
/// `ClawWorkspace` is pure I/O and owns no logger.
public enum WorkspaceWarning: Sendable, Equatable {
  /// `skills/<skill>/SKILL.md` exists but is unusable (no `---` fence, malformed YAML, or missing
  /// `name`/`description`).
  case invalidSkillManifest(skill: String)

  /// A manifest's `name` is not a valid skill identifier: lowercase alphanumeric segments joined
  /// by single hyphens, 1–64 characters.
  case invalidSkillName(directory: String, name: String)

  /// A manifest's `name` disagrees with its own directory name. The loader resolves a name to a
  /// directory, so the two identities must agree.
  case skillNameDirectoryMismatch(directory: String, name: String)

  /// Several manifests claim the same `name`; every claimant is dropped, since picking one would
  /// silently shadow the other.
  case duplicateSkillName(name: String, directories: [String])

  /// A skill directory resolves outside the workspace (a symlink). The loader refuses to serve a
  /// body from there, so indexing it would advertise a skill that can never load.
  case escapingSkillDirectory(directory: String)

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
