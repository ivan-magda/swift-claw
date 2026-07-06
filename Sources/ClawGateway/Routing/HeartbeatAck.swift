import Foundation

/// Spec §12 ack suppression, in code: a heartbeat result counts as an ack ONLY when it carries the
/// `HEARTBEAT_OK` token as a leading and/or trailing marker AND the surviving remainder is trivial
/// padding. Such a result is dropped before delivery — no outbox rows, audited `heartbeatSuppressed`.
/// The token is required: heartbeats are an opt-in alerting feature, so a concise reply that lacks
/// the token is treated as an owner-relevant alert and must deliver, never be silently suppressed.
enum HeartbeatAck {
  static let token = "HEARTBEAT_OK"

  /// 300 chars (pinned compile-time, spec §13 — not config): generous enough for model politeness
  /// wrapped around the ack token, far below any owner-meaningful report. This is the cap on the
  /// remainder that survives AFTER a leading/trailing token has been stripped; it only ever applies
  /// once the token has been confirmed present.
  static let maxAckChars = 300

  /// A heartbeat reply is an ack only when the `HEARTBEAT_OK` token appears as a leading and/or
  /// trailing marker and the remainder left after stripping it is ≤ `maxAckChars`. No token means
  /// not an ack — the reply is owner-relevant and must be delivered.
  static func isAck(_ content: String) -> Bool {
    var remainder = content.trimmingCharacters(in: .whitespacesAndNewlines)
    var tokenStripped = false
    if remainder.hasPrefix(token) {
      remainder = String(remainder.dropFirst(token.count))
      tokenStripped = true
    }
    if remainder.hasSuffix(token) {
      remainder = String(remainder.dropLast(token.count))
      tokenStripped = true
    }
    remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    return tokenStripped && remainder.count <= maxAckChars
  }
}
