import ClawCore
import Testing

@Suite("Route switch eligibility")
struct RouteSwitchTests {
  @Test("nothing-generated rejections switch with a long cooldown")
  func persistentCausesSwitchLong() {
    // given
    let causes: [ProviderError] = [
      .quotaLimited(retryAfterSeconds: nil),
      .authenticationRequired,
      .accessDenied,
    ]

    // when / then
    for cause in causes {
      #expect(cause.routeSwitchPersistence == .long)
    }
  }

  @Test("pre-stream head failures switch with a short cooldown")
  func transportCausesSwitchShort() {
    // given
    let causes: [ProviderError] = [
      .connectFailed(message: "reset"),
      .rejected(status: 429, message: "rate limited"),
    ]

    // when / then
    for cause in causes {
      #expect(cause.routeSwitchPersistence == .short)
    }
  }

  @Test("causes that may already owe tokens never switch")
  func ineligibleCausesStay() {
    // given
    let causes: [ProviderError] = [
      .retryable(status: 500, message: "boom"),
      .terminal(status: 400, message: "bad"),
      .cleanRejection(status: 400),
      .invalidProviderState,
      .visionUnsupported,
    ]

    // when / then
    for cause in causes {
      #expect(cause.routeSwitchPersistence == nil)
    }
  }

  @Test("a provider verdict of mayHaveStarted vetoes an otherwise eligible cause")
  func providerVerdictVetoes() {
    // given
    let failure = ProviderFailure(
      cause: .quotaLimited(retryAfterSeconds: 30),
      accounting: .mayHaveStarted(observing: 12)
    )

    // when
    let decision = RouteSwitch.permits(failure)

    // then
    #expect(decision == nil)
  }

  @Test("a clean provider verdict keeps an eligible cause eligible")
  func cleanVerdictPermits() {
    // given
    let failure = ProviderFailure(
      cause: .quotaLimited(retryAfterSeconds: 30),
      accounting: .notStarted
    )

    // when
    let decision = RouteSwitch.permits(failure)

    // then
    #expect(decision == .long)
  }

  @Test("a non-provider error never switches")
  func foreignErrorStays() {
    // given
    struct Unrelated: Error {}

    // when
    let decision = RouteSwitch.permits(Unrelated())

    // then
    #expect(decision == nil)
  }
}
