import ClawCore

/// One round-trip before it is sent: its index in the segment, the call identity every usage row
/// of the round is recorded under, and the context the round sends.
struct RoundPlan {
  let index: Int
  let callID: ProviderCallID
  let wire: [ChatMessage]
  let turn: TurnFrame
}

/// A round-trip the provider answered and the route that answered it. Every usage row of the round
/// is minted through that route's accountant, so each one charges the route that did the work.
struct AnsweredRound {
  let plan: RoundPlan
  let response: ChatResponse
  let accountant: ProviderUsageAccountant
}

/// What one round's tool calls produced: an observation for every executed call, the first action
/// the gate parked for approval, and whether cancellation cut the batch short.
struct ToolBatch {
  var observations: [ToolObservation] = []
  var pending: PendingToolAction?
  var interrupted = false

  /// Gives every proposal without an observation an error one, the parked action included, so
  /// history replay finds a result for every original proposal.
  mutating func recordUnexecuted(_ calls: [ToolCall]) {
    let observedIDs = Set(observations.map(\.callID))
    for call in calls where !observedIDs.contains(call.id) {
      observations.append(
        ToolObservation(
          callID: call.id,
          toolName: call.name,
          content: "Tool call was not executed because the run was cancelled.",
          status: .error,
          ingestedUntrusted: false
        )
      )
    }
  }
}
