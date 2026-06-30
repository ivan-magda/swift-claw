import Foundation

/// The result of loading a workspace file in the grapheme domain (spec §6, §6.1, §12).
public struct LoadedFile: Sendable, Equatable {
  /// What happened, so the caller can apply the right policy. `ClawWorkspace` decides none of it:
  /// `.present` -> usable; `.overCap` -> omit + owner notice (§6.1); `.missing` -> omit silently
  /// (normal, §6); `.unreadable` -> omit + log (§12).
  public enum Outcome: Sendable, Equatable {
    case present
    case overCap
    case missing
    case unreadable
  }

  public let outcome: Outcome

  /// File content for `.present`. Empty for every other outcome - in particular `.overCap` returns
  /// no text so a caller can never accidentally inject a truncated hand-curated file
  /// (`ARCHITECTURE.md` §9.3: "ERROR, never silent truncation").
  public let text: String

  /// Original grapheme length before any cap check. Non-zero on `.present` and `.overCap`; drives
  /// the §6.1 "N/cap" owner notice. Zero on `.missing`/`.unreadable`.
  public let graphemeCount: Int

  public init(outcome: Outcome, text: String, graphemeCount: Int) {
    self.outcome = outcome
    self.text = text
    self.graphemeCount = graphemeCount
  }

  /// A file that does not exist: normal, omit silently, never throws (spec §6).
  public static let missing = LoadedFile(outcome: .missing, text: "", graphemeCount: 0)
}
