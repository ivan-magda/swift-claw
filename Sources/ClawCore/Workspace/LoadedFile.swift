import Foundation

/// The result of loading a workspace file in the grapheme domain.
public struct LoadedFile: Sendable, Equatable {
  /// What happened, so the caller can apply the right policy. `ClawWorkspace` decides none of it:
  /// `.present` -> usable; `.overCap` -> omit + owner notice; `.missing` -> omit silently
  /// (normal); `.unreadable` -> omit + log.
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
  /// the "N/cap" owner notice. Zero on `.missing`/`.unreadable`.
  public let graphemeCount: Int

  public init(outcome: Outcome, text: String, graphemeCount: Int) {
    self.outcome = outcome
    self.text = text
    self.graphemeCount = graphemeCount
  }

  /// A file that does not exist: normal, omit silently, never throws.
  public static let missing = LoadedFile(outcome: .missing, text: "", graphemeCount: 0)
}
