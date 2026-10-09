import CoreFoundation
import Foundation

public enum CanonicalJSON {
  public static func encode<Value: Encodable>(_ value: Value) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    guard let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8)
    else {
      return nil
    }

    return json
  }

  package static func data(fromJSONObject value: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(value) else {
      throw CanonicalJSONError.invalidJSONObject
    }

    var data = try JSONSerialization.data(
      withJSONObject: value,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0A)

    return data
  }

  package static func data<Value: Encodable>(encoding value: Value) throws -> Data {
    let encoded = try JSONEncoder().encode(value)
    return try data(fromJSONObject: JSONSerialization.jsonObject(with: encoded))
  }

  /// Decodes `bytes` only when they are already the canonical encoding of the decoded value.
  ///
  /// Decoding alone tolerates unknown keys, reordered keys and alternate JSON spellings, so a
  /// persisted record could change on disk and still decode to the same value. Re-encoding and
  /// comparing the bytes closes that gap.
  package static func decodeExactly<Value: Codable>(
    _ type: Value.Type,
    from bytes: Data
  ) -> Value? {
    guard let value = try? JSONDecoder().decode(type, from: bytes),
          let canonicalBytes = try? data(encoding: value),
          canonicalBytes == bytes
    else {
      return nil
    }

    return value
  }

  /// JSONSerialization bridges booleans through NSNumber; exclude CFBoolean before accepting an
  /// integer so strict frozen schemas cannot treat `true` as `1`.
  package static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }

    #if canImport(ObjectiveC)
      let cfNumber = number as CFNumber
    #else
      let cfNumber = unsafeBitCast(number, to: CFNumber.self)
    #endif

    guard CFNumberIsFloatType(cfNumber) == false else {
      return nil
    }

    var raw: Int64 = 0
    let hasInt64Value = CFNumberGetValue(cfNumber, .sInt64Type, &raw)
    guard hasInt64Value,
          number.compare(NSNumber(value: raw)) == .orderedSame
    else {
      return nil
    }

    return Int(exactly: raw)
  }

  // swiftlint:disable discouraged_optional_boolean
  package static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return nil
    }
    return number.boolValue
  }  // swiftlint:enable discouraged_optional_boolean
}

package enum CanonicalJSONError: Error, Sendable, Equatable {
  case invalidJSONObject
}
