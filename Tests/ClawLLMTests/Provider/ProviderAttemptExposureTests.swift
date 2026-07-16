import Testing

@testable import ClawCore
@testable import ClawLLM

@Suite struct ProviderAttemptExposureTests {
  @Test func anAttemptStartsHavingExposedNothing() {
    // given / when
    let exposure = ProviderAttemptExposure()

    // then
    #expect(exposure.accounting == .notStarted)
  }

  @Test func theHandoffMakesExposureConservative() throws {
    // given
    let exposure = ProviderAttemptExposure()

    // when
    try exposure.beginHandoff()

    // then — the request may have been written even if no response head ever arrives
    #expect(exposure.accounting == .mayHaveStarted(observing: 0))
  }

  @Test func aCancelledCallerIsRefusedTheHandoffAndStaysNotStarted() async {
    // given
    let exposure = ProviderAttemptExposure()

    // when — the handoff runs on a task that has already observed cancellation
    let refusal = await Task { () -> (any Error)? in
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      do {
        try exposure.beginHandoff()
        return nil
      } catch {
        return error
      }
    }
    .value

    // then — the submission is refused outright, so the attempt still claims nothing was sent
    #expect(refusal is CancellationError)
    #expect(exposure.accounting == .notStarted)
  }

  @Test func aProvenCleanAttemptReturnsToNotStarted() throws {
    // given — an attempt that reached the transport
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()

    // when — a recognized error head or a definitely-not-sent failure proves it generated nothing
    exposure.noteProvenClean()

    // then
    #expect(exposure.accounting == .notStarted)
  }

  @Test func eachAttemptReEstablishesItsOwnExposure() throws {
    // given — a first attempt that was proven clean and retried
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()
    exposure.noteProvenClean()

    // when
    try exposure.beginHandoff()

    // then — exposure is re-established per attempt rather than carried over from the last one
    #expect(exposure.accounting == .mayHaveStarted(observing: 0))
  }

  @Test func observedTokensOnlyEverRise() throws {
    // given
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()

    // when — a later chunk restates a smaller count
    exposure.noteObserved(completionTokens: 12)
    exposure.noteObserved(completionTokens: 3)

    // then — the bound is a lower bound and must not walk back down
    #expect(exposure.accounting == .mayHaveStarted(observing: 12))
  }

  @Test func aNegativeObservationCannotRefundTokens() throws {
    // given
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()

    // when — a miscount offers a negative
    exposure.noteObserved(completionTokens: -5)

    // then — floored, never credited
    #expect(exposure.accounting == .mayHaveStarted(observing: 0))
  }

  @Test func cancellationBeforeTheHandoffIsRaw() {
    // given
    let exposure = ProviderAttemptExposure()

    // when
    let error = exposure.cancellationError()

    // then
    #expect(error is CancellationError)
  }

  @Test func cancellationAfterAnAmbiguousHandoffIsTyped() throws {
    // given
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()
    exposure.noteObserved(completionTokens: 7)

    // when
    let error = exposure.cancellationError()

    // then — the model may have been asked anyway, so the tokens still have to be accounted for
    #expect(error as? ProviderInferenceCancellation == ProviderInferenceCancellation(observing: 7))
  }

  @Test func cancellationAfterACleanResetIsRawAgain() throws {
    // given — a clean rejection won the race back to `notStarted`
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()
    exposure.noteProvenClean()

    // when
    let error = exposure.cancellationError()

    // then
    #expect(error is CancellationError)
  }

  @Test func aHandoffThatWinsBeforeCancellationLeavesTheAttemptConservative() throws {
    // given — the handoff transition wins the lock first
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()

    // when — the caller's cancellation arrives only after the attempt reached the transport
    let accounting = exposure.accounting

    // then — an already-handed-off attempt cannot claim it never started
    #expect(accounting == .mayHaveStarted(observing: 0))
  }

  @Test func aCancellationThatWinsBeforeTheCleanResetStaysConservative() throws {
    // given — an attempt that reached the transport
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()

    // when — cancellation is read before any clean-rejection reset has run
    let error = exposure.cancellationError()

    // then — with no proven-clean reset yet, the model may have been asked, so accounting is typed
    #expect(error as? ProviderInferenceCancellation == ProviderInferenceCancellation(observing: 0))
  }

  @Test func repeatedHandoffsDoNotWalkExposureBackToNotStarted() throws {
    // given — an attempt whose clean reset returned it to `notStarted`
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()
    exposure.noteProvenClean()

    // when — the same instance is handed off again and then reset again
    try exposure.beginHandoff()
    #expect(exposure.accounting == .mayHaveStarted(observing: 0))
    exposure.noteProvenClean()

    // then — each transition stands on its own; nothing is carried over from a prior handoff
    #expect(exposure.accounting == .notStarted)
  }

  @Test func responseDataRaisesTheConservativeLowerBound() throws {
    // given — an attempt that reached the transport and observed generated tokens
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()

    // when — response data reports a running count
    exposure.noteObserved(completionTokens: 9)

    // then — the exposure carries that lower bound for accounting a later failure
    #expect(exposure.accounting == .mayHaveStarted(observing: 9))
  }

  @Test func failurePairsACauseWithTheCurrentAccounting() throws {
    // given — an attempt that reached the transport and observed some output
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()
    exposure.noteObserved(completionTokens: 4)

    // when — the engine builds a natural failure through the reducer
    let failure = exposure.failure(.terminal(status: nil, message: "boom"))

    // then — the reducer is the single source of the accounting the failure carries
    #expect(failure.cause == .terminal(status: nil, message: "boom"))
    #expect(failure.accounting == .mayHaveStarted(observing: 4))
  }

  @Test func failureOnAProvenCleanAttemptIsNotStarted() throws {
    // given — a recognized non-success head returned the attempt to `notStarted`
    let exposure = ProviderAttemptExposure()
    try exposure.beginHandoff()
    exposure.noteProvenClean()

    // when
    let failure = exposure.failure(.accessDenied)

    // then — a clean rejection writes no estimated usage row
    #expect(failure.accounting == .notStarted)
  }
}
