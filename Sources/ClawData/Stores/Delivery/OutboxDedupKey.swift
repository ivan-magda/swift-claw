import Foundation

enum OutboxDedupKey {
  static func make(runId: Int64, stepIndex: Int) -> String {
    "\(runId):\(stepIndex)"
  }
}
