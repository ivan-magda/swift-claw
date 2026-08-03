import ClawCore
import Foundation

/// Applies the process redaction vocabulary before remote catalog metadata reaches provider-facing
/// definitions or an owner-facing approval prompt.
struct MCPMetadataSanitizer: Sendable {
  private let redactor: SecretRedactor

  init(redactor: SecretRedactor) {
    self.redactor = redactor
  }

  func text(_ raw: String) -> String {
    redactor.redact(raw)
  }

  func schema(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object):
      var redacted: [String: JSONValue] = [:]
      for key in object.keys.sorted() {
        guard let child = object[key] else {
          continue
        }
        redacted[text(key)] = schema(child)
      }
      return .object(redacted)
    case .array(let values):
      return .array(values.map(schema))
    case .string(let value):
      return .string(text(value))
    case .null, .bool, .number:
      return value
    }
  }

  /// A remote name is untrusted text inside a fixed approval row. Controls and Unicode formatting
  /// marks are removed so it cannot create a second row, reverse the display, or hide its suffix.
  func displayName(_ raw: String) -> String {
    let visible = text(raw).unicodeScalars.map { scalar -> String in
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator:
        return " "
      default:
        return String(scalar)
      }
    }.joined()
    let singleLine = visible.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let usable = singleLine.isEmpty ? "remote tool" : singleLine
    return TextTruncation.cap(usable, maxGraphemes: MCPToolNamer.nameLimit)
  }
}
