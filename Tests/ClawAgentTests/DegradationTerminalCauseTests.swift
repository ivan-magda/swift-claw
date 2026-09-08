import ClawCore
import Testing

@testable import ClawAgent

/// A degraded turn delivers a canned owner-facing failure notice in place of an answer, so it is
/// always an infrastructure, entitlement or context failure — never evidence about the task. Two
/// provider outages must not be able to synthesize a behavioral lesson about the model, which is
/// the boundary this mapping holds.
@Suite struct DegradationTerminalCauseTests {
  @Test(arguments: [
    (DegradationKind.providerUnavailable, TerminalCause.providerFailure),
    (.authenticationRequired, .providerFailure),
    (.accessDenied, .providerFailure),
    (.quotaLimited(retryAfterSeconds: nil), .providerFailure),
    (.invalidProviderState, .providerFailure),
    (.accountingFailed, .providerFailure),
    (.outputTruncated, .incomplete),
    (.contextUnavailable, .incomplete),
    (.visionUnsupported, .incomplete),
  ])
  func noDegradationKindBecomesTaskEvidence(kind: DegradationKind, expected: TerminalCause) {
    // given / when
    let cause = kind.terminalCause

    // then
    #expect(cause == expected, "degradation \(kind) mapped to \(cause)")
    #expect(cause != .taskCompleted)
  }
}
