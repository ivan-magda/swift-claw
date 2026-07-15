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
}
