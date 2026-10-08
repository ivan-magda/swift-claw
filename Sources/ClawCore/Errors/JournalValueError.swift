public enum JournalValueError: Error, Sendable, Equatable {
  case invalidSourceID
  case textTooLong(field: String)
  case tooManyEvidenceEntries
  case sourceTooLarge
}
