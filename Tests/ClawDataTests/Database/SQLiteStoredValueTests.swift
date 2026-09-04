import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct SQLiteStoredValueTests {
  @Test func exactStorageClassMatrix() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let row = try queue.read { db in
      try #require(
        try Row.fetchOne(
          db,
          sql: """
            SELECT NULL AS null_value, 0 AS zero_value, 1 AS one_value, 2 AS two_value,
              9223372036854775807 AS maximum_integer, 1.5 AS real_value,
              '1' AS text_value, X'01' AS blob_value
            """
        )
      )
    }

    // when
    let nullableInt64 = try #require(
      SQLiteStoredValue.nullableInt64(in: row, column: "null_value")
    )
    let nullableInt = try #require(
      SQLiteStoredValue.nullableInt(in: row, column: "null_value")
    )
    let nullableDouble = try #require(
      SQLiteStoredValue.nullableDouble(in: row, column: "null_value")
    )
    let nullableString = try #require(
      SQLiteStoredValue.nullableString(in: row, column: "null_value")
    )

    // then — collapsing missing/wrong-class values into SQL NULL, widening Boolean truth, or
    // coercing storage classes violates the decoder; the nearest accepted view matrix reaches
    // only non-optional fields.
    #expect(nullableInt64.value == nil)
    #expect(nullableInt.value == nil)
    #expect(nullableDouble.value == nil)
    #expect(nullableString.value == nil)
    #expect(nonnullableDecodersRejectNull(in: row))
    #expect(nullableDecodersRejectMissingColumn(in: row))
    #expect(nullableDecodersRejectWrongStorageClass(in: row))
    #expect(booleanDomainIsExact(in: row))
    #expect(SQLiteStoredValue.data(in: row, column: "blob_value") == Data([0x01]))
    #expect(SQLiteStoredValue.data(in: row, column: "text_value") == nil)
    #expect(SQLiteStoredValue.int64(in: row, column: "one_value") == 1)
    #expect(SQLiteStoredValue.int(in: row, column: "one_value") == 1)
    #expect(nativeIntsRespectPlatformRange(in: row))
    #expect(SQLiteStoredValue.string(in: row, column: "text_value") == "1")
    #expect(doublesUseNumericStorageClasses(in: row))
  }
}

private extension SQLiteStoredValueTests {
  func nonnullableDecodersRejectNull(in row: Row) -> Bool {
    SQLiteStoredValue.int64(in: row, column: "null_value") == nil
      && SQLiteStoredValue.int(in: row, column: "null_value") == nil
      && isAbsent(SQLiteStoredValue.boolean(in: row, column: "null_value"))
      && SQLiteStoredValue.double(in: row, column: "null_value") == nil
      && SQLiteStoredValue.string(in: row, column: "null_value") == nil
      && SQLiteStoredValue.data(in: row, column: "null_value") == nil
  }

  func nullableDecodersRejectMissingColumn(in row: Row) -> Bool {
    isAbsent(SQLiteStoredValue.nullableInt64(in: row, column: "missing_value"))
      && isAbsent(SQLiteStoredValue.nullableInt(in: row, column: "missing_value"))
      && isAbsent(SQLiteStoredValue.nullableDouble(in: row, column: "missing_value"))
      && isAbsent(SQLiteStoredValue.nullableString(in: row, column: "missing_value"))
  }

  func nullableDecodersRejectWrongStorageClass(in row: Row) -> Bool {
    isAbsent(SQLiteStoredValue.nullableInt64(in: row, column: "text_value"))
      && isAbsent(SQLiteStoredValue.nullableInt(in: row, column: "text_value"))
      && isAbsent(SQLiteStoredValue.nullableDouble(in: row, column: "text_value"))
      && isAbsent(SQLiteStoredValue.nullableString(in: row, column: "blob_value"))
  }

  func booleanDomainIsExact(in row: Row) -> Bool {
    guard
      case .falseValue? = SQLiteStoredValue.boolean(in: row, column: "zero_value"),
      case .trueValue? = SQLiteStoredValue.boolean(in: row, column: "one_value")
    else {
      return false
    }
    return isAbsent(SQLiteStoredValue.boolean(in: row, column: "two_value"))
      && isAbsent(SQLiteStoredValue.boolean(in: row, column: "text_value"))
  }

  func nativeIntsRespectPlatformRange(in row: Row) -> Bool {
    let expected = Int(exactly: Int64.max)
    let decoded = SQLiteStoredValue.int(in: row, column: "maximum_integer")
    let nullable = SQLiteStoredValue.nullableInt(in: row, column: "maximum_integer")
    switch (expected, nullable) {
    case (.some(let expected), .some(let nullable)):
      return decoded == expected && nullable.value == expected
    case (nil, nil):
      return decoded == nil
    default:
      return false
    }
  }

  func doublesUseNumericStorageClasses(in row: Row) -> Bool {
    guard
      let nullableInteger = SQLiteStoredValue.nullableDouble(in: row, column: "one_value"),
      let nullableReal = SQLiteStoredValue.nullableDouble(in: row, column: "real_value")
    else {
      return false
    }
    return SQLiteStoredValue.double(in: row, column: "one_value") == 1
      && SQLiteStoredValue.double(in: row, column: "real_value") == 1.5
      && SQLiteStoredValue.double(in: row, column: "text_value") == nil
      && nullableInteger.value == 1
      && nullableReal.value == 1.5
  }

  func isAbsent<Value>(_ value: Value?) -> Bool {
    switch value {
    case nil:
      true
    case .some:
      false
    }
  }
}
