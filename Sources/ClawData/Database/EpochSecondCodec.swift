import Foundation

/// Codec for `.integer` UTC epoch-second `Date` columns. A raw `Date` bind would let GRDB
/// serialize the value as an ISO-8601 string and break integer comparisons such as
/// `expires_ts <= now` or the scheduler's compare-and-advance equality. Rounding to whole seconds
/// keeps that equality exact; `date(fromEpoch:)` preserves the column's optional so a NULL stays nil.
enum EpochSecondCodec {
  static func epoch(_ instant: Date) -> Int64 {
    Int64(instant.timeIntervalSince1970.rounded())
  }

  static func date(fromEpoch value: Int64?) -> Date? {
    value.map { seconds in
      Date(timeIntervalSince1970: TimeInterval(seconds))
    }
  }
}
