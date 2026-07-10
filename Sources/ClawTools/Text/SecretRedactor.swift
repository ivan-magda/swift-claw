import Foundation

/// Exact-value secret redaction for tool OUTPUT (`file_read`; `web_fetch` extracted text).
/// The replacement token matches the arg guard's audit rendering vocabulary.
public struct SecretRedactor: Sendable {
  public static let replacement = "[REDACTED:secret-value]"

  private let secretValues: [String]

  public init(secretValues: [String]) {
    self.secretValues = secretValues.filter { value in
      value.isEmpty == false
    }
  }

  public func redact(_ text: String) -> String {
    var redacted = text

    for secret in secretValues {
      redacted = redacted.replacingOccurrences(of: secret, with: Self.replacement)
    }

    return redacted
  }
}
