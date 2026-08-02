import Foundation

/// Pure workspace file I/O and parsing. No budget, LLM, or config knowledge: per-file
/// grapheme caps arrive as a parameter and the caller decides how to react to each `LoadedFile`.
public protocol WorkspaceReading: Sendable {
  /// Loads a fixed workspace file in the grapheme domain. A missing file returns `.missing`, an
  /// undecodable file `.unreadable`, an over-cap file `.overCap` (no consumable text), and never
  /// throws. `maxGraphemes` nil means no cap.
  func load(file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile

  /// Loads a dated daily log `memory/<day>.md`, where `day` is a `YYYY-MM-DD` stem. A stem that is
  /// not `YYYY-MM-DD`, or a missing file, returns `.missing`. Same outcome rules as `load`.
  func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile

  /// Scans `skills/<name>/SKILL.md` and returns one `SkillDescriptor` per usable skill, plus a
  /// `WorkspaceWarning` for each present-but-unusable manifest. A manifest is usable only when its
  /// frontmatter carries a non-empty `description` and a `name` that is both an agentskills.io
  /// identifier (`^[a-z0-9]+(-[a-z0-9]+)*$`, 1–64 characters) and equal to its own directory name;
  /// the three ways to fail that yield `.invalidSkillManifest`, `.invalidSkillName`, and
  /// `.skillNameDirectoryMismatch`. A name claimed by several directories has no principled winner,
  /// so every claimant is dropped under one `.duplicateSkillName` — a conformance must never
  /// silently shadow one with another. Descriptions are collapsed to a single line and capped, so
  /// one manifest cannot occupy several index rows. A missing `skills/` directory or a subdirectory
  /// with no `SKILL.md` is skipped without a warning; a `skills/` directory that exists but cannot
  /// be listed yields `.unreadableSkillsDirectory`. Never a half-entry, never a crash. Descriptors
  /// are sorted by directory name.
  func scanSkills() -> SkillScanResult
}
