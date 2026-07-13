import Foundation

/// Deterministic sorted-keys JSON re-encoding for approval hashing: the same logical value always
/// renders the same bytes, so an approval's args hash stays stable across encode passes. Slashes
/// are left unescaped so the canonical form reads as the plain owner-facing text.
public enum CanonicalJSON {
  public static func encode<Value: Encodable>(_ value: Value) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    guard
      let data = try? encoder.encode(value),
      let json = String(data: data, encoding: .utf8)
    else {
      return nil
    }

    return json
  }
}
