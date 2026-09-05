import ClawCore

enum LearningReplies {
  static let resetFailed = "Learning reset failed. Nothing changed. Run the command again."

  static func resetConfirmation(jobId: Int64, label: String?) -> String {
    let identity = label.map { "Schedule \(jobId) · \($0)" } ?? "Schedule \(jobId)"
    return """
      \(identity)
      Reset its learning?

      This will start a new learning epoch with an empty stable lesson set, close every live \
      trial, invalidate pending feedback targets and challenges, and abandon learning calls that \
      have not started. Calls already in flight may finish, but only their usage is retained. \
      Existing runs keep the lessons they were pinned to, and learning history is retained. \
      The exact current effects are resolved when you confirm.

      Reply yes to confirm or no to cancel.
      """
  }

  static func resetOutcome(_ outcome: LearningResetOutcome, jobId: Int64) -> String {
    switch outcome {
    case .applied(let receipt):
      return """
        Learning reset applied for schedule \(jobId): epoch \(receipt.inputs.oldEpoch.value) → \
        \(receipt.result.newEpoch.value), \(receipt.result.closedTrials.count) live trial(s) \
        closed, \(receipt.result.invalidatedTargetCount) target(s) and \
        \(receipt.result.invalidatedChallengeCount) challenge(s) invalidated, \
        \(receipt.result.staleNoCallOperationIds.count) not-started call(s) abandoned, \
        \(receipt.result.inFlightOperationIds.count) in-flight call(s) left usage-only.
        """
    case .alreadyReset(let receipt):
      let epoch = receipt.result.newEpoch.value
      return "Learning for schedule \(jobId) was already reset at epoch \(epoch)."
    case .unarmed:
      return "Schedule \(jobId) has no learning state to reset."
    case .notFound:
      return "No schedule with id \(jobId). Nothing was reset."
    }
  }
}
