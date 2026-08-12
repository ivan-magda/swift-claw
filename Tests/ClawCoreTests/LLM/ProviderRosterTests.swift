import ClawCore
import ClawTestSupport
import Testing

@Suite("Provider roster")
struct ProviderRosterTests {
  @Test("a clear primary starts the call, fallback or not")
  func clearPrimaryStartsTheCall() {
    // given
    let withFallback = makeRoster(hasFallback: true)
    let alone = makeRoster(hasFallback: false)

    // when
    let started = withFallback.startingRoute(primaryIsCooling: false)
    let startedAlone = alone.startingRoute(primaryIsCooling: false)

    // then
    #expect(started.position == .primary)
    #expect(started.binding.configuredReference == "primary-model")
    #expect(startedAlone.position == .primary)
  }

  @Test("a cooling primary starts the call on the fallback")
  func coolingPrimaryStartsOnTheFallback() {
    // given
    let roster = makeRoster(hasFallback: true)

    // when
    let started = roster.startingRoute(primaryIsCooling: true)

    // then
    #expect(started.position == .fallback)
    #expect(started.binding.configuredReference == "fallback-model")
  }

  @Test("a cooling primary with nowhere to go still starts the call")
  func coolingLonePrimaryStillStartsTheCall() {
    // given — the one route configured is walled off; refusing to start would strand the turn
    let roster = makeRoster(hasFallback: false)

    // when
    let started = roster.startingRoute(primaryIsCooling: true)

    // then
    #expect(started.position == .primary)
  }

  @Test("the primary fails over to the fallback")
  func primaryFailsOverToTheFallback() {
    // given
    let roster = makeRoster(hasFallback: true)

    // when
    let next = roster.failover(from: .primary)

    // then
    #expect(next?.position == .fallback)
    #expect(next?.binding.configuredReference == "fallback-model")
  }

  @Test("a lone primary has nowhere to fail over to")
  func lonePrimaryHasNoFailover() {
    // given
    let roster = makeRoster(hasFallback: false)

    // then
    #expect(roster.hasFallback == false)
    #expect(roster.failover(from: .primary) == nil)
  }

  @Test("the fallback is the last route")
  func fallbackIsTheLastRoute() {
    // given
    let roster = makeRoster(hasFallback: true)

    // then
    #expect(roster.failover(from: .fallback) == nil)
  }
}

private extension ProviderRosterTests {
  /// Bindings named after their position, so a selection's identity is readable in the expectation
  /// rather than inferred from the position it was asked for.
  func makeBinding(_ reference: String) -> LLMRouteBinding {
    makeSingleRouteRoster(
      provider: SequenceProvider([]),
      wireModel: "\(reference)-wire",
      configuredReference: reference
    ).primary
  }

  func makeRoster(hasFallback: Bool) -> ProviderRoster {
    ProviderRoster(
      primary: makeBinding("primary-model"),
      fallback: hasFallback ? makeBinding("fallback-model") : nil
    )
  }
}
