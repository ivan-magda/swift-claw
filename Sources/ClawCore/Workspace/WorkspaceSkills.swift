/// The workspace-skills convention, in one place because three modules have to agree on it: the
/// scanner that walks the directory, the loader that reads a manifest back, and the prompt carve-out
/// that grants the fence label its meaning. Separate literals per module could drift apart silently,
/// and a drifted `fenceLabel` either strands the carve-out or hands it to the wrong content.
public enum WorkspaceSkills {
  /// Directory under the workspace root holding one subdirectory per skill.
  public static let directoryName = "skills"

  /// Manifest file inside each skill directory.
  public static let manifestName = "SKILL.md"

  /// The fence label the skills index row and every loaded skill body render under. The system
  /// prompt's follow-this-as-guidance exception is written against exactly this label.
  public static let fenceLabel = "skills"
}
