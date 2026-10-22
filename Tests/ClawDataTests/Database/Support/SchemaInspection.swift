import GRDB

/// Schema reads and constraint matching shared by the migration suites.
enum SchemaInspection {
  static func columnNames(_ reader: some DatabaseReader, table: String) throws -> [String] {
    try reader.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
        row["name"] as String
      }
    }
  }

  /// Matches the failure mode, not merely "something threw" — a schema that lost a constraint
  /// still throws for the wrong reason, and that must not read as a pass.
  static func isConstraintViolation(_ error: any Error, mentioning kind: String) -> Bool {
    guard let databaseError = error as? DatabaseError else {
      return false
    }
    return databaseError.resultCode.primaryResultCode == .SQLITE_CONSTRAINT
      && (databaseError.message?.contains(kind) ?? false)
  }
}
