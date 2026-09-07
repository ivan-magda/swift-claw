import Foundation

/// The canonical byte form of a digest's input fields.
///
/// Fields join on a separator no field may contain, rather than on a printable character. Route
/// references, model ids and version strings all legitimately carry punctuation — `configuredRoute`
/// is the owner's `CLAW_LLM_MODEL` verbatim, and `llama3:8b`-style ids are ordinary — so a printable
/// separator lets two different field lists produce one digest by shifting a field boundary, which
/// would pool work the digest exists to keep apart.
public enum CanonicalDigestInput {
  /// Not representable in a route reference, a version string or a hex digest, so no field can
  /// contain it and no escaping is needed.
  private static let separator = "\u{0}"

  /// What an absent optional field reads as. Distinct from the separator so a nil field can never
  /// read as a field boundary, and distinct from `""` so it cannot collide with a field that is
  /// genuinely empty.
  public static let absentField = "\u{1}"

  public static func joined(_ fields: [String]) -> String {
    fields.joined(separator: separator)
  }
}
