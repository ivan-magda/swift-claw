import ClawCore
import Testing

@testable import ClawAgent

@Suite struct AgentRuntimeAccountingTests {
  @Test func attemptFailureCauseMatrixIsClosed() {
    // given — every provider cause is represented once; the wrapper is the shape provider runtimes
    // actually throw, so losing `ProviderError.cause(of:)` unwrapping cannot pass this matrix.
    let providerCases: [(ProviderError, AttemptFailureCause?)] = [
      (.connectFailed(message: "refused"), .transportFailure),
      (.transportFailure(message: "dropped"), .transportFailure),
      (.retryable(status: 500, message: "retry"), nil),
      (.rejected(status: 429, message: "rejected"), nil),
      (.terminal(status: 400, message: "terminal"), nil),
      (.authenticationRequired, nil),
      (.accessDenied, nil),
      (.quotaLimited(retryAfterSeconds: 30), nil),
      (.cleanRejection(status: 400), nil),
      (.invalidProviderState, nil),
      (.visionUnsupported, nil),
      (.credentialRefreshCompleted, .credentialRefreshCompleted),
      (.credentialRefreshExhausted, .credentialRefreshExhausted),
      (.credentialStateUnavailable, .credentialStateUnavailable),
      (.partialStreamWithoutCompletedTerminal, .partialStreamWithoutCompletedTerminal),
      (.localOutputLimit, .localOutputLimit),
      (.modelIdentityMismatch, .modelIdentityMismatch),
    ]

    // when
    let observed = providerCases.map { cause, _ in
      AgentFailureClassification(
        error: ProviderFailure(cause: cause, accounting: .notStarted)
      ).attemptFailureCause
    }

    // then — provider causes remain descriptive and payload-free; retry policy belongs to the caller
    // that consumes this diagnostic.
    for (index, entry) in providerCases.enumerated() {
      #expect(observed[index] == entry.1)
    }

    // and — lifecycle/deadline signals remain distinct from provider causes.
    #expect(
      AgentFailureClassification(error: CancellationError()).attemptFailureCause
        == .processInterruption
    )
    #expect(
      AgentFailureClassification(
        error: ProviderInferenceCancellation(observing: 1)
      ).attemptFailureCause == .deadline
    )
    let racedResponse = ChatResponse(
      content: "finished",
      finishReason: "stop",
      usage: nil,
      costFromProvider: nil
    )
    #expect(
      AgentFailureClassification(
        error: RacedDeadlineSuccess(response: racedResponse)
      ).attemptFailureCause == .deadline
    )

    struct ForeignFailure: Error {}
    #expect(AgentFailureClassification(error: ForeignFailure()).attemptFailureCause == nil)
  }
}
