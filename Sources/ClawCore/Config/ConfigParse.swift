import Foundation

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
