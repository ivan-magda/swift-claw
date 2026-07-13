import Foundation

/// Shared skeleton for the numeric env-config knobs: trim, treat absent/blank as the caller's
/// fallback, parse, then enforce the caller's bound — throwing the caller's own `ConfigError` so
/// each knob keeps its distinct vocabulary. Trimming is `.whitespacesAndNewlines` everywhere, so a
/// value's acceptance never depends on which knob happens to strip trailing newlines.
enum ConfigParse {
  static func boundedInt(
    _ raw: String?,
    default fallback: Int,
    range: ClosedRange<Int>,
    onInvalid: (String) -> ConfigError
  ) throws -> Int {
    try boundedIntOrNil(raw, range: range, onInvalid: onInvalid) ?? fallback
  }

  /// The optional-ceiling variant: absent/blank yields `nil` (the caller derives its own default)
  /// rather than a fixed fallback.
  static func boundedIntOrNil(
    _ raw: String?,
    range: ClosedRange<Int>,
    onInvalid: (String) -> ConfigError
  ) throws -> Int? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else {
      return nil
    }

    guard let value = Int(trimmed), range.contains(value) else {
      throw onInvalid(trimmed)
    }

    return value
  }

  static func positiveDouble(
    _ raw: String?,
    default fallback: Double,
    onInvalid: (String) -> ConfigError
  ) throws -> Double {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else {
      return fallback
    }

    guard let value = Double(trimmed), value > 0 else {
      throw onInvalid(trimmed)
    }

    return value
  }
}
