import ClawCore

enum LearningReplies {
  static let resetFailed = "Learning reset failed. Nothing changed. Run the command again."

  static func resetConfirmation(jobID: Int64, label: String?) -> String {
    let identity =
      label.map {
        "Schedule \(jobID) · \($0)"
      } ?? "Schedule \(jobID)"
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

  static func resetOutcome(_ outcome: LearningResetOutcome, jobID: Int64) -> String {
    switch outcome {
    case .applied(let receipt):
      return """
        Learning reset applied for schedule \(jobID): epoch \(receipt.inputs.oldEpoch.value) → \
        \(receipt.result.newEpoch.value), \(receipt.result.closedTrials.count) live trial(s) \
        closed, \(receipt.result.invalidatedTargetCount) target(s) and \
        \(receipt.result.invalidatedChallengeCount) challenge(s) invalidated, \
        \(receipt.result.staleNoCallOperationIDs.count) not-started call(s) abandoned, \
        \(receipt.result.inFlightOperationIDs.count) in-flight call(s) left usage-only.
        """
    case .alreadyReset(let receipt):
      let epoch = receipt.result.newEpoch.value
      return "Learning for schedule \(jobID) was already reset at epoch \(epoch)."
    case .unarmed:
      return "Schedule \(jobID) has no learning state to reset."
    case .notFound:
      return "No schedule with id \(jobID). Nothing was reset."
    }
  }
}
