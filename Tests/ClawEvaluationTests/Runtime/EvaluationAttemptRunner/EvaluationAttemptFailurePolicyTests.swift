import ClawAgent
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationAttemptFailurePolicyTests {
  @Test func replacementAllowlistAndPersistedReasonsStayFrozen() {
    // given — this is the complete runtime diagnostic vocabulary. The nearest integration test
    // covers credential and terminal-free causes, but not the closed allowlist or every persisted
    // transport/deadline/interruption string.
    let cases: [(AttemptFailureCause, String?)] = [
      (.transportFailure, "transport_failure"),
      (.credentialRefreshCompleted, nil),
      (.credentialRefreshExhausted, "credential_refresh_exhausted"),
      (.credentialStateUnavailable, nil),
      (.deadline, "deadline"),
      (.processInterruption, "process_interruption"),
      (
        .partialStreamWithoutCompletedTerminal,
        "partial_stream_without_completed_terminal"
      ),
      (.localOutputLimit, nil),
      (.modelIdentityMismatch, nil),
    ]

    // when
    let observed = cases.map { cause, _ in
      EvaluationAttemptFailurePolicy.replacementReason(for: cause)
    }

    // then — every descriptive cause appears exactly once, and only the protocol's five approved
    // causes cross the worker/controller replacement boundary.
    #expect(cases.count == AttemptFailureCause.allCases.count)
    for cause in AttemptFailureCause.allCases {
      #expect(cases.filter { $0.0 == cause }.count == 1)
    }
    for (index, entry) in cases.enumerated() {
      #expect(observed[index] == entry.1)
    }
    #expect(EvaluationAttemptFailurePolicy.replacementReason(for: nil) == nil)
  }
}
