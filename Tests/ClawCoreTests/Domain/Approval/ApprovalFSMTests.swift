import Testing

@testable import ClawCore

@Suite struct ApprovalFSMTests {
  private struct Transition {
    let state: ApprovalState
    let event: ApprovalEvent
    let expected: ApprovalState
  }

  @Test func legalTransitions() {
    // given — the full legal set of ARCHITECTURE §19.1's ApprovalState table
    let legal = [
      Transition(state: .pending, event: .approve, expected: .approved),
      Transition(state: .pending, event: .reject, expected: .rejected),
      Transition(state: .pending, event: .expire, expected: .expired),
    ]

    for transition in legal {
      // when
      let next = ApprovalFSM.reduce(state: transition.state, on: transition.event)

      // then
      #expect(next == transition.expected)
    }
  }

  @Test func illegalTransitionsHaveNoDefaultArm() {
    // given — every remaining state×event cell: resolved rows never move again
    let illegal: [(state: ApprovalState, event: ApprovalEvent)] = [
      (.approved, .approve),
      (.approved, .reject),
      (.approved, .expire),
      (.rejected, .approve),
      (.rejected, .reject),
      (.rejected, .expire),
      (.expired, .approve),
      (.expired, .reject),
      (.expired, .expire),
    ]

    for transition in illegal {
      // when
      let next = ApprovalFSM.reduce(state: transition.state, on: transition.event)

      // then
      #expect(next == nil)
    }
  }
}
