import Foundation

/// Shared parser for the positive-Int64 arguments bot commands accept (job ids, memory ids). nil
/// signals a missing/invalid argument so the router replies with usage rather than guessing.
public enum PositiveInt64 {
  public static func parse(_ raw: String) -> Int64? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let value = Int64(trimmed), value > 0 else {
      return nil
    }

    return value
  }
}
