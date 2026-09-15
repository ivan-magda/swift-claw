import Foundation

/// A non-fatal diagnostic from a workspace scan. `ClawWorkspace` is pure I/O and owns neither
/// logging nor presentation, so consumers decide where the shared owner-facing reason appears.
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

  /// `skills/` itself resolves outside the workspace (a symlinked directory). It anchors every
  /// per-skill containment check, so nothing under it can be trusted to be inside the workspace.
  case skillsDirectoryOutsideWorkspace

  /// The complete reason an owner needs to identify and repair this rejected scan entry.
  public var ownerFacingReason: String {
    switch self {
    case .invalidSkillManifest(let skill):
      return """
        Skill `\(skill)`: `SKILL.md` needs `---` frontmatter with `name` and `description`; skipped.
        """
    case .invalidSkillName(let directory, let name):
      return """
        Skill `\(directory)`: name `\(name)` must be lowercase letters, digits and single hyphens \
        (1–64 characters); skipped.
        """
    case .skillNameDirectoryMismatch(let directory, let name):
      return "Skill `\(directory)`: manifest name `\(name)` must match the directory name; skipped."
    case .duplicateSkillName(let name, let directories):
      let claimants = directories.map { directory in
        "`\(directory)`"
      }.joined(separator: ", ")
      return "Skill name `\(name)` is claimed by \(claimants); all of them skipped, rename one."
    case .escapingSkillDirectory(let directory):
      return """
        Skill `\(directory)`: its `SKILL.md` resolves outside the workspace, which I can't load \
        from; skipped. Copy the skill in instead of linking to it.
        """
    case .unreadableSkillsDirectory:
      return """
        The `skills` directory couldn't be read; all skills skipped. Check its permissions and try \
        again.
        """
    case .skillsDirectoryOutsideWorkspace:
      return """
        The `skills` directory resolves outside the workspace, which I can't load from; all skills \
        skipped. Move it into the workspace instead of linking to it.
        """
    }
  }
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
