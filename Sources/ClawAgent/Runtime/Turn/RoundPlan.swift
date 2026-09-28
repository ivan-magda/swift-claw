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
