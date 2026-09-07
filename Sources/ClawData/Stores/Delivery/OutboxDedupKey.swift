import ClawCore
import Foundation

/// The unique `dedup_key` that is an outbound row's identity. A run's chunks key on the run and
/// step; a learning notice, which has no run, keys on the subject it speaks about and the chunk's
/// ordinal. The `learning:` prefix keeps the two spaces from ever colliding.
enum OutboxDedupKey {
  static func make(runId: Int64, stepIndex: Int) -> String {
    "\(runId):\(stepIndex)"
  }

  static func make(subjectDigest: String, ordinal: Int) -> String {
    "\(DeliverySource.learning.rawValue):\(subjectDigest):\(ordinal)"
  }
}
