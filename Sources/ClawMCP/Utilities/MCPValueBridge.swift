import ClawCore
import Foundation
import MCP

/// Translates between the SDK's `Value` tree and ClawCore's `JSONValue`.
///
/// Both describe the same JSON, but the SDK splits integers from doubles and folds data-URL strings
/// into a case of their own. Bridging structurally rather than round-tripping through an encoder
/// keeps the pass total — nothing here can throw on a schema we are about to advertise.
public enum MCPValueBridge {
  public static func jsonValue(_ value: Value) -> JSONValue {
    switch value {
    case .null:
      return .null
    case .bool(let flag):
      return .bool(flag)
    case .int(let number):
      return .integer(number)
    case .double(let number):
      return .number(number)
    case .string(let text):
      return .string(text)
    case .data(let mimeType, let bytes):
      // It arrived as a data URL, so it goes back as the string it was.
      return .string(bytes.dataURLEncoded(mimeType: mimeType))
    case .array(let items):
      return .array(items.map(jsonValue))
    case .object(let members):
      return .object(members.mapValues(jsonValue))
    }
  }

  public static func value(_ json: JSONValue) -> Value {
    switch json {
    case .null:
      return .null
    case .bool(let flag):
      return .bool(flag)
    case .integer(let number):
      return .int(number)
    case .number(let number):
      return numberValue(number)
    case .string(let text):
      return .string(text)
    case .array(let items):
      return .array(items.map(value))
    case .object(let members):
      return .object(members.mapValues(value))
    }
  }
}

// MARK: - Numbers

private extension MCPValueBridge {
  /// JSON has one number type and `JSONValue` keeps it as a `Double`, so an integral argument would
  /// otherwise reach a server that declared an integer parameter as `1.0` and be refused.
  static func numberValue(_ number: Double) -> Value {
    guard let integer = Int(exactly: number) else {
      return .double(number)
    }
    return .int(integer)
  }
}
