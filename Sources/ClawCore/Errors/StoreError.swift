public enum StoreError: Error, Sendable, Equatable {
  case openFailed(String)
  case migrationFailed(String)
  case unexpected(String)
  case diskFull
}
