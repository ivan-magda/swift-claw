import ClawCore
import Foundation

/// The argument plumbing every dangerous-tier tool shares. Their approvals bind a canonical
/// action, so decode, canonical encoding, and the refusal shape must agree byte for byte no
/// matter which tool asked — a second copy would drift an approval away from what runs.
enum DangerousToolSupport {
  static func decode<Value: Decodable>(_ type: Value.Type, from arguments: JSONValue) -> Value? {
    guard let data = try? JSONEncoder().encode(arguments) else {
      return nil
    }
    return try? JSONDecoder().decode(type, from: data)
  }

  static func canonicalJSON<Value: Encodable>(_ value: Value) -> String? {
    CanonicalJSON.encode(value)
  }

  static func errorPayload(_ reason: String, redactor: SecretRedactor) -> ToolPayload {
    ToolPayload(
      content: redactor.redact(reason),
      status: .error,
      ingestedUntrusted: false,
      readPrivateData: false
    )
  }
}
