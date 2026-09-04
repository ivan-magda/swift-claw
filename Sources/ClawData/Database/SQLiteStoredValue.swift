import Foundation
import GRDB

/// Exact SQLite storage-class decoding for persisted values that must fail closed on bad rows.
enum SQLiteStoredValue {
  enum BooleanValue {
    case falseValue
    case trueValue
  }

  struct Nullable<Value> {
    let value: Value?
  }

  static func int64(in row: Row, column: String) -> Int64? {
    guard case .int64(let value) = databaseValue(in: row, column: column)?.storage else {
      return nil
    }
    return value
  }

  static func int(in row: Row, column: String) -> Int? {
    guard let value = int64(in: row, column: column) else {
      return nil
    }
    return Int(exactly: value)
  }

  static func boolean(in row: Row, column: String) -> BooleanValue? {
    switch int64(in: row, column: column) {
    case 0:
      return .falseValue
    case 1:
      return .trueValue
    default:
      return nil
    }
  }

  static func double(in row: Row, column: String) -> Double? {
    guard let storage = databaseValue(in: row, column: column)?.storage else {
      return nil
    }
    switch storage {
    case .double(let value):
      return value
    case .int64(let value):
      return Double(value)
    case .null, .string, .blob:
      return nil
    }
  }

  static func string(in row: Row, column: String) -> String? {
    guard case .string(let value) = databaseValue(in: row, column: column)?.storage else {
      return nil
    }
    return value
  }

  static func data(in row: Row, column: String) -> Data? {
    guard case .blob(let value) = databaseValue(in: row, column: column)?.storage else {
      return nil
    }
    return value
  }

  static func nullableInt64(in row: Row, column: String) -> Nullable<Int64>? {
    guard let storage = databaseValue(in: row, column: column)?.storage else {
      return nil
    }
    switch storage {
    case .null:
      return Nullable(value: nil)
    case .int64(let value):
      return Nullable(value: value)
    case .double, .string, .blob:
      return nil
    }
  }

  static func nullableInt(in row: Row, column: String) -> Nullable<Int>? {
    guard let decoded = nullableInt64(in: row, column: column) else {
      return nil
    }
    guard let value = decoded.value else {
      return Nullable(value: nil)
    }
    guard let exact = Int(exactly: value) else {
      return nil
    }
    return Nullable(value: exact)
  }

  static func nullableDouble(in row: Row, column: String) -> Nullable<Double>? {
    guard let storage = databaseValue(in: row, column: column)?.storage else {
      return nil
    }
    switch storage {
    case .null:
      return Nullable(value: nil)
    case .double(let value):
      return Nullable(value: value)
    case .int64(let value):
      return Nullable(value: Double(value))
    case .string, .blob:
      return nil
    }
  }

  static func nullableString(in row: Row, column: String) -> Nullable<String>? {
    guard let storage = databaseValue(in: row, column: column)?.storage else {
      return nil
    }
    switch storage {
    case .null:
      return Nullable(value: nil)
    case .string(let value):
      return Nullable(value: value)
    case .int64, .double, .blob:
      return nil
    }
  }

  private static func databaseValue(in row: Row, column: String) -> DatabaseValue? {
    row[column] as DatabaseValue?
  }
}
