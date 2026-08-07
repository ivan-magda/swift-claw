import ClawCore
import ClawTestSupport
import Testing

@Suite("Route cooldown")
struct RouteCooldownTests {
  @Test("an unarmed route is not cooling")
  func unarmedRouteIsHot() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(longSeconds: 900, clock: clock)

    // when
    let cooling = await cooldown.isCooling(routeIndex: 0)

    // then
    #expect(cooling == false)
  }

  @Test("a long-tier arm cools the route for its window")
  func longArmCools() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(longSeconds: 900, clock: clock)

    // when
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.isCooling(routeIndex: 0) == true)
    #expect(await cooldown.remainingSeconds(routeIndex: 0) == 900)
  }

  @Test("the window expires and the route is probed again")
  func windowExpires() async throws {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)

    // when
    try await clock.sleep(for: .seconds(901))

    // then
    #expect(await cooldown.isCooling(routeIndex: 0) == false)
  }

  @Test("a failed probe re-arms with a doubled window")
  func failedProbeDoubles() async throws {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)
    try await clock.sleep(for: .seconds(901))

    // when
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.remainingSeconds(routeIndex: 0) == 1800)
  }

  @Test("doubling stops at the cap")
  func doublingStopsAtCap() async throws {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(longSeconds: 900, capSeconds: 3600, clock: clock)

    // when
    for _ in 0..<6 {
      await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)
      try await clock.sleep(for: .seconds(3601))
    }
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.remainingSeconds(routeIndex: 0) == 3600)
  }

  @Test("a retry-after hint larger than the tier default wins")
  func retryAfterHintWins() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(shortSeconds: 60, longSeconds: 900, clock: clock)

    // when
    await cooldown.arm(routeIndex: 0, persistence: .short, retryAfterSeconds: 120)

    // then
    #expect(await cooldown.remainingSeconds(routeIndex: 0) == 120)
  }

  @Test("a retry-after hint smaller than the tier default is ignored")
  func smallRetryAfterIgnored() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(longSeconds: 900, clock: clock)

    // when
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: 30)

    // then
    #expect(await cooldown.remainingSeconds(routeIndex: 0) == 900)
  }

  @Test("a success clears the window and resets the doubling")
  func clearResetsDoubling() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)

    // when
    _ = await cooldown.recordSuccess(routeIndex: 0)
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.isCooling(routeIndex: 0) == true)
    #expect(await cooldown.remainingSeconds(routeIndex: 0) == 900)
  }

  @Test("a lapsed window is reported exactly once")
  func expiryIsReportedOnce() async throws {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)

    // when
    try await clock.sleep(for: .seconds(901))

    // then — the window is consumed and dropped in the one hop, so no second success re-reports it
    #expect(await cooldown.recordSuccess(routeIndex: 0) == true)
    #expect(await cooldown.recordSuccess(routeIndex: 0) == false)
  }

  @Test("a success on a live window reports nothing and still drops it")
  func liveWindowReportsNoExpiry() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)

    // when / then — the route answered, so there is nothing to tell the owner about a recovery
    #expect(await cooldown.recordSuccess(routeIndex: 0) == false)
    #expect(await cooldown.isCooling(routeIndex: 0) == false)
  }

  @Test("routes cool independently")
  func routesAreIndependent() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = RouteCooldown(longSeconds: 900, clock: clock)

    // when
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.isCooling(routeIndex: 0) == true)
    #expect(await cooldown.isCooling(routeIndex: 1) == false)
  }

  @Test("the actor is usable through its tracking protocol")
  func usableThroughTrackingProtocol() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown: any RouteCooldownTracking = RouteCooldown(longSeconds: 900, clock: clock)

    // when
    await cooldown.arm(routeIndex: 0, persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.isCooling(routeIndex: 0) == true)
  }
}
