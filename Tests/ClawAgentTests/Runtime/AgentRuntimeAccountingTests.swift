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
      AgentRuntime.attemptFailureCause(
        for: ProviderFailure(cause: cause, accounting: .notStarted)
      )
    }

    // then — provider causes remain descriptive and payload-free; retry policy belongs to the caller
    // that consumes this diagnostic.
    for (index, entry) in providerCases.enumerated() {
      #expect(observed[index] == entry.1)
    }

    // and — lifecycle/deadline signals remain distinct from provider causes.
    #expect(
      AgentRuntime.attemptFailureCause(for: CancellationError()) == .processInterruption
    )
    #expect(
      AgentRuntime.attemptFailureCause(
        for: ProviderInferenceCancellation(observing: 1)
      ) == .deadline
    )
    let racedResponse = ChatResponse(
      content: "finished",
      finishReason: "stop",
      usage: nil,
      costFromProvider: nil
    )
    #expect(
      AgentRuntime.attemptFailureCause(
        for: RacedDeadlineSuccess(response: racedResponse)
      ) == .deadline
    )

    struct ForeignFailure: Error {}
    #expect(AgentRuntime.attemptFailureCause(for: ForeignFailure()) == nil)
  }
}
