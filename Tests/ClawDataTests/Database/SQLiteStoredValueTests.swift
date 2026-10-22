import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct SQLiteStoredValueTests {
  @Test
  func exactStorageClassMatrix() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
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
    let nullableInt64 = try #require(SQLiteStoredValue.nullableInt64(in: row, column: "null_value"))
    let nullableInt = try #require(SQLiteStoredValue.nullableInt(in: row, column: "null_value"))
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
    expectNonnullableDecodersRejectNull(in: row)
    expectNullableDecodersRejectMissingColumn(in: row)
    expectNullableDecodersRejectWrongStorageClass(in: row)
    expectBooleanDomainIsExact(in: row)
    #expect(SQLiteStoredValue.data(in: row, column: "blob_value") == Data([0x01]))
    #expect(SQLiteStoredValue.data(in: row, column: "text_value") == nil)
    #expect(SQLiteStoredValue.int64(in: row, column: "one_value") == 1)
    #expect(SQLiteStoredValue.int(in: row, column: "one_value") == 1)
    expectNativeIntsRespectPlatformRange(in: row)
    #expect(SQLiteStoredValue.string(in: row, column: "text_value") == "1")
    expectDoublesUseNumericStorageClasses(in: row)
  }
}

// MARK: - Stored Value Assertions

private extension SQLiteStoredValueTests {
  func expectNonnullableDecodersRejectNull(in row: Row) {
    #expect(SQLiteStoredValue.int64(in: row, column: "null_value") == nil)
    #expect(SQLiteStoredValue.int(in: row, column: "null_value") == nil)
    #expect(SQLiteStoredValue.boolean(in: row, column: "null_value") == nil)
    #expect(SQLiteStoredValue.double(in: row, column: "null_value") == nil)
    #expect(SQLiteStoredValue.string(in: row, column: "null_value") == nil)
    #expect(SQLiteStoredValue.data(in: row, column: "null_value") == nil)
  }

  func expectNullableDecodersRejectMissingColumn(in row: Row) {
    #expect(SQLiteStoredValue.nullableInt64(in: row, column: "missing_value") == nil)
    #expect(SQLiteStoredValue.nullableInt(in: row, column: "missing_value") == nil)
    #expect(SQLiteStoredValue.nullableDouble(in: row, column: "missing_value") == nil)
    #expect(SQLiteStoredValue.nullableString(in: row, column: "missing_value") == nil)
  }

  func expectNullableDecodersRejectWrongStorageClass(in row: Row) {
    #expect(SQLiteStoredValue.nullableInt64(in: row, column: "text_value") == nil)
    #expect(SQLiteStoredValue.nullableInt(in: row, column: "text_value") == nil)
    #expect(SQLiteStoredValue.nullableDouble(in: row, column: "text_value") == nil)
    #expect(SQLiteStoredValue.nullableString(in: row, column: "blob_value") == nil)
  }

  func expectBooleanDomainIsExact(in row: Row) {
    #expect(SQLiteStoredValue.boolean(in: row, column: "zero_value") == .falseValue)
    #expect(SQLiteStoredValue.boolean(in: row, column: "one_value") == .trueValue)
    #expect(SQLiteStoredValue.boolean(in: row, column: "two_value") == nil)
    #expect(SQLiteStoredValue.boolean(in: row, column: "text_value") == nil)
  }

  func expectNativeIntsRespectPlatformRange(in row: Row) {
    let expected = Int(exactly: Int64.max)
    #expect(SQLiteStoredValue.int(in: row, column: "maximum_integer") == expected)
    let nullable = SQLiteStoredValue.nullableInt(in: row, column: "maximum_integer")
    if let expected {
      #expect(nullable?.value == expected)
    } else {
      #expect(nullable == nil)
    }
  }

  func expectDoublesUseNumericStorageClasses(in row: Row) {
    #expect(SQLiteStoredValue.double(in: row, column: "one_value") == 1)
    #expect(SQLiteStoredValue.double(in: row, column: "real_value") == 1.5)
    #expect(SQLiteStoredValue.double(in: row, column: "text_value") == nil)
    #expect(SQLiteStoredValue.nullableDouble(in: row, column: "one_value")?.value == 1)
    #expect(SQLiteStoredValue.nullableDouble(in: row, column: "real_value")?.value == 1.5)
  }
}
