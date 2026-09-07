import ClawCore
import Foundation
import GRDB

// MARK: - Schema V12

extension ClawDatabase {
  /// Gives `learning_operations` the claim key it shipped without. The logical hypothesis an
  /// operation answers covers the evaluator's prompt, schema and rubric versions, and the v11 table
  /// has no columns for those — so the key travels as one digest, and the partial unique index
  /// below is what makes "at most one live attempt per key" a database invariant rather than a race
  /// the claim transaction happens to win.
  ///
  /// The column is nullable because SQLite cannot add a `NOT NULL` column without a default, and a
  /// literal default would be a real key digest that every row collides on. Nothing wrote this
  /// table before this migration, so no row exists that could carry a null.
  static func addLearningOperationClaimKey(_ db: Database) throws {
    try db.alter(table: "learning_operations") { table in
      table.add(column: "key_digest", .text)
    }
    try db.create(
      index: "idx_learning_operations_key",
      on: "learning_operations",
      columns: ["key_digest"]
    )
    // The three nonterminal states. A terminal row keeps its key digest so a superseding attempt
    // can find its predecessor, which is exactly why the uniqueness has to be partial.
    let liveStates = [
      LearningOperationState.pending.rawValue,
      LearningOperationState.claimed.rawValue,
      LearningOperationState.started.rawValue,
    ]
    try db.create(
      index: "idx_learning_operations_live_key",
      on: "learning_operations",
      columns: ["key_digest"],
      options: [.unique],
      condition: liveStates.contains(Column("state"))
    )
  }
}
