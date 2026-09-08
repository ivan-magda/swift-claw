import Foundation
import Testing

@testable import ClawCore

/// Deterministic eligibility runs before any learning model spend, and its verdict is terminal. The
/// boundary this suite guards is that only a run that committed a model-authored answer to the task
/// ever reaches the evaluator: feeding it a provider outage or a clipped answer would let
/// infrastructure noise synthesize a behavioral lesson about the model.
@Suite struct EligibilityClassifierTests {
  @Test func onlyTaskEvidenceReachesTheEvaluator() {
    // given
    let cases: [(TerminalCause, LearningEligibility)] = [
      (.taskCompleted, .eligibleTaskEvidence),
      (.providerFailure, .transientInfrastructureFailure),
      (.storageFailure, .transientInfrastructureFailure),
      (.budgetStopped, .transientInfrastructureFailure),
      (.policyBlocked, .policyOrSecurityBlock),
      (.approvalUnresolved, .ownerInterruption),
      (.approvalDenied, .ownerInterruption),
      (.ownerCancelled, .ownerInterruption),
      (.superseded, .ownerInterruption),
      (.unknown, .unsupportedTerminalState),
      (.incomplete, .insufficientEvidence),
    ]
    #expect(cases.count == TerminalCause.allCases.count)

    for (cause, expected) in cases {
      // when
      let actual = EligibilityClassifier.classify(
        Self.settlement(cause: cause),
        transcript: .complete
      )

      // then
      #expect(actual == expected, "cause \(cause.rawValue)")
    }
    #expect(
      LearningEligibility.allCases.allSatisfy { value in
        value.reachesEvaluator == (value == .eligibleTaskEvidence)
      }
    )
  }

  @Test func anIncompleteTranscriptOverridesASuccessfulTerminal() {
    // given — the run completed, but a proposed tool call has no observation row
    let transcript = EvidenceTranscript(proposedCalls: 2, observedCalls: 1, finalOutputBytes: 400)

    // when
    let actual = EligibilityClassifier.classify(
      Self.settlement(cause: .taskCompleted),
      transcript: transcript
    )

    // then
    #expect(actual == .insufficientEvidence)
  }

  @Test func anOverCapFinalOutputIsRefusedRatherThanTruncated() {
    // given — a completed run whose answer is one byte past what evidence may carry whole
    let transcript = EvidenceTranscript(
      proposedCalls: 0,
      observedCalls: 0,
      finalOutputBytes: EvidenceLimits.finalOutputByteCap + 1
    )

    // when
    let actual = EligibilityClassifier.classify(
      Self.settlement(cause: .taskCompleted),
      transcript: transcript
    )

    // then — a clipped answer would read to the evaluator as the model's own
    #expect(actual == .insufficientEvidence)
  }
}

// MARK: - Fixtures

private extension EligibilityClassifierTests {
  static func settlement(cause: TerminalCause) -> RunSettlement {
    RunSettlement(
      runId: 1,
      winningState: .done,
      terminalCause: cause,
      terminalAt: Date(timeIntervalSince1970: 1_782_000_600),
      settledAt: Date(timeIntervalSince1970: 1_782_000_600)
    )
  }
}
