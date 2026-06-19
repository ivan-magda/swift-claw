import ClawCore

/// Bundle of the stores as ClawCore protocol types — lets `clawd` wire persistence without
/// importing GRDB. The backing DatabasePool is retained by the stores.
public struct ClawStores: Sendable {
  public let allowlist: any AllowlistStore
  public let processed: any ProcessedUpdateStore
  public let cursor: any UpdateCursorStore
}

extension ClawDatabase {
  /// Opens the WAL pool, runs migrations, and hands back the protocol-typed stores.
  public static func openStores(path: String) throws -> ClawStores {
    let pool = try makePool(path: path)
    try migrate(pool)
    return ClawStores(
      allowlist: AllowlistStoreGRDB(writer: pool),
      processed: ProcessedUpdateStoreGRDB(writer: pool),
      cursor: UpdateCursorStoreGRDB(writer: pool)
    )
  }
}
