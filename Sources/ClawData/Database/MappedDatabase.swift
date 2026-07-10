import ClawCore
import Foundation
import GRDB

/// The only database handle a store holds. It exposes exactly the two seam methods —
/// `writeMapping`/`readMapping` — so the raw `write`/`read` (which would leak a GRDB
/// `DatabaseError` past the store boundary) is structurally unreachable from store code,
/// not merely forbidden by convention.
struct MappedDatabase: Sendable {
  private let writer: any DatabaseWriter

  init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// A store write whose GRDB failures are translated to domain `StoreError`s at the seam
  /// (e.g. a full disk → `StoreError.diskFull`).
  func writeMapping<Value>(_ updates: (Database) throws -> Value) throws(StoreError) -> Value {
    do {
      return try writer.write(updates)
    } catch {
      throw ClawDatabase.classifyError(error)
    }
  }

  /// A store read whose GRDB failures are translated to domain `StoreError`s at the seam.
  func readMapping<Value>(_ value: (Database) throws -> Value) throws(StoreError) -> Value {
    do {
      return try writer.read(value)
    } catch {
      throw ClawDatabase.classifyError(error)
    }
  }
}
