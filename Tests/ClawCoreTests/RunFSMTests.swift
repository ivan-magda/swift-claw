import Testing

@testable import ClawCore

@Suite struct RunFSMTests {
  private struct Transition {
    let state: RunState
    let event: RunEvent
    let expected: RunState
  }

  @Test func legalTransitions() {
    // given
    let legal = [
      Transition(state: .pending, event: .pickUp, expected: .running),
      Transition(state: .pending, event: .fail, expected: .failed),
      Transition(state: .pending, event: .cancel, expected: .cancelled),
      Transition(state: .pending, event: .supersede, expected: .superseded),
      Transition(state: .running, event: .complete, expected: .done),
      Transition(state: .running, event: .fail, expected: .failed),
      Transition(state: .running, event: .cancel, expected: .cancelled),
      Transition(state: .running, event: .supersede, expected: .superseded),
    ]

    for transition in legal {
      // when
      let next = RunFSM.reduce(state: transition.state, on: transition.event)

      // then
      #expect(next == transition.expected)
    }
  }

  @Test func illegalTransitionsHaveNoDefaultArm() {
    // given
    let illegal: [(state: RunState, event: RunEvent)] = [
      (.done, .complete),
      (.failed, .pickUp),
      (.cancelled, .complete),
      (.superseded, .fail),
      (.pending, .complete),
      (.running, .pickUp),
    ]

    for transition in illegal {
      // when
      let next = RunFSM.reduce(state: transition.state, on: transition.event)

      // then
      #expect(next == nil)
    }
  }
}
