import CoreFoundation
import Foundation

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

  /// JSONSerialization bridges booleans through NSNumber; exclude CFBoolean before accepting an
  /// integer so strict frozen schemas cannot treat `true` as `1`.
  package static func integer(_ value: Any?) -> Int? {
    guard
      let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
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
    guard
      CFNumberGetValue(cfNumber, .sInt64Type, &raw),
      number.compare(NSNumber(value: raw)) == .orderedSame
    else {
      return nil
    }

    return Int(exactly: raw)
  }

  package static func boolean(_ value: Any?) -> Bool? {
    if let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    {
      return number.boolValue
    }
    return nil
  }
}

package enum CanonicalJSONError: Error, Sendable, Equatable {
  case invalidJSONObject
}
