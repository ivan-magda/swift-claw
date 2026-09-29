import ClawCore
import ClawTestSupport
import Testing

@Suite("Route failover")
struct RouteFailoverTests {
  @Test(
    "a permitted switch moves to the fallback and cools the primary for the cause's window",
    arguments: [
      (ProviderError.authenticationRequired, 300),
      (.connectFailed(message: "reset"), 60),
      (.quotaLimited(retryAfterSeconds: 900), 900),
    ]
  )
  func permittedSwitchCoolsThePrimary(cause: ProviderError, windowSeconds: Int) async throws {
    // given — a long tier configured shorter than the longest throttle hint a provider can send
    let cooldown = PrimaryRouteCooldown(
      shortSeconds: 60,
      longSeconds: 300,
      clock: ScriptedClock { _ in }
    )

    // when
    let failover = await RouteSwitch.failover(
      after: cause,
      from: .primary,
      roster: makeRoster(hasFallback: true),
      cooldown: cooldown
    )

    // then
    let route = try #require(failover?.route)
    #expect(route.position == .fallback)
    #expect(await cooldown.remainingSeconds() == windowSeconds)
  }

  @Test("a lone primary is left unarmed, because its failure has nowhere to switch to")
  func refusedSwitchLeavesThePrimaryUnarmed() async {
    // given — a cause that switches whenever a fallback exists
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: ScriptedClock { _ in })

    // when
    let failover = await RouteSwitch.failover(
      after: ProviderError.quotaLimited(retryAfterSeconds: nil),
      from: .primary,
      roster: makeRoster(hasFallback: false),
      cooldown: cooldown
    )

    // then
    #expect(failover == nil)
    #expect(await cooldown.isCooling() == false)
  }
}
