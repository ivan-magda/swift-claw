import Testing

@testable import ClawCore

/// The run lifecycle is a small reducer: `RunFSM.reduce` is the single source of truth for which
/// `(state, event)` pairs are legal. These tests pin the Inc 1 transition table and prove that an
/// illegal pair returns `nil` rather than silently defaulting to some state.
@Suite struct RunFSMTests {
  /// One row of the legal transition table: applying `event` to `state` must yield `expected`.
  private struct Transition {
    let state: RunState
    let event: RunEvent
    let expected: RunState
  }

  @Test func legalInc1Transitions() {
    // given — every transition the Inc 1 lifecycle is allowed to make
    let legal = [
      Transition(state: .pending, event: .pickUp, expected: .running),
      Transition(state: .running, event: .complete, expected: .done),
      Transition(state: .running, event: .fail, expected: .failed),
      Transition(state: .pending, event: .fail, expected: .failed),
    ]

    for transition in legal {
      // when
      let next = RunFSM.reduce(state: transition.state, on: transition.event)

      // then
      #expect(next == transition.expected)
    }
  }

  @Test func illegalTransitionsHaveNoDefaultArm() {
    // given — pairs that must never move the state (no default arm hides them)
    let illegal: [(state: RunState, event: RunEvent)] = [
      (.done, .complete),  // a finished run can't complete again
      (.failed, .pickUp),  // a failed run can't be picked back up
      (.done, .fail),  // a finished run can't be failed
    ]

    for transition in illegal {
      // when
      let next = RunFSM.reduce(state: transition.state, on: transition.event)

      // then
      #expect(next == nil)
    }
  }
}
