import Foundation

enum PositiveInt64 {
  static func parse(_ raw: String) -> Int64? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let value = Int64(trimmed), value > 0 else {
      return nil
    }

    return value
  }
}
