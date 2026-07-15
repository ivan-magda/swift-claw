import ClawCore
import Foundation
import GRDB

// MARK: - Provider Replay State Coding

/// The single seam between a `messages` row and the opaque replay state an assistant anchor may
/// carry. Every write path binds through `values`, and the read path decodes through `decode`, so
/// the column names, the pair rule, and the per-message cap have one definition rather than one per
/// caller.
///
/// Nothing here interprets the payload: the bytes belong to the adapter that issued them.
enum ProviderStateCoding {
  /// Per-message replay-state ceiling. State past it is refused at load rather than replayed: a
  /// payload this large is corruption or a foreign writer, and either way the anchor is more useful
  /// without it than the session is broken by it.
  static let maxPayloadBytes = 1 << 20

  static let issuerColumn = "provider_state_issuer"
  static let payloadColumn = "provider_state"

  /// The pair, in the order `values` binds it — for any SELECT whose rows reach `decode`.
  static let selection = "\(issuerColumn), \(payloadColumn)"

  /// The bound pair for an INSERT. A nil state binds two NULLs, which is what the schema's
  /// both-or-neither CHECK requires and what every route that mints no state produces.
  static func values(_ state: ProviderExchangeState?) -> [(any DatabaseValueConvertible)?] {
    [state?.issuer, state?.payload]
  }

  /// Reads the pair off an already-fetched row, keeping state only when it is intact.
  ///
  /// Non-throwing *and* non-fatal by construction, and that is the point: a row is here only
  /// because its query already succeeded, so anything wrong with these two values is bad data,
  /// never a failed read. A real SQLite failure surfaces from the fetch itself and reaches the
  /// caller's `readMapping`/`writeMapping` as a typed `StoreError` — it can never arrive as a
  /// dropped state.
  ///
  /// Refused: a half-written pair, a payload the `BLOB`-affinity column did not store as bytes, an
  /// issuer stored as anything but text, a payload past the per-message cap, and a column the query
  /// never selected. Each drops the optional state alone; the message it belongs to stays whole,
  /// because the state was never what made the message usable.
  static func decode(_ row: Row) -> ProviderExchangeState? {
    // The optional subscript, because GRDB's non-optional one is a `try!` that traps on a column
    // the SELECT never named. A caller that forgets `selection` should lose the state, not the
    // process.
    let issuerValue = row[issuerColumn] as DatabaseValue? ?? .null
    let payloadValue = row[payloadColumn] as DatabaseValue? ?? .null

    // Storage classes, not typed decodes: `row["…"] as Data?` would happily coerce a TEXT value
    // into bytes and hand the adapter a payload no issuer ever wrote.
    guard
      case .string(let issuer) = issuerValue.storage,
      case .blob(let payload) = payloadValue.storage,
      payload.count <= maxPayloadBytes
    else {
      return nil
    }

    return ProviderExchangeState(issuer: issuer, payload: payload)
  }
}

// MARK: - Message Row Inserts

/// The one INSERT seam for a `messages` row that may anchor replay state. Callers name the columns
/// their row needs; the state pair is appended here, so an anchor path cannot quietly omit it and
/// persist a proposal apart from the state it was minted with.
enum MessageRowInsert {
  static func execute(
    _ db: Database,
    columns: [String],
    values: [(any DatabaseValueConvertible)?],
    providerState: ProviderExchangeState?
  ) throws {
    let allColumns =
      columns + [ProviderStateCoding.issuerColumn, ProviderStateCoding.payloadColumn]
    let placeholders = Array(repeating: "?", count: allColumns.count).joined(separator: ", ")

    try db.execute(
      sql: """
        INSERT INTO messages(\(allColumns.joined(separator: ", ")))
        VALUES (\(placeholders))
        """,
      arguments: StatementArguments(values + ProviderStateCoding.values(providerState))
    )
  }
}
