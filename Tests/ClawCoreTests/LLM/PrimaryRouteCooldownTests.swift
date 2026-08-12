import ClawCore
import ClawTestSupport
import Testing

@Suite("Primary route cooldown")
struct PrimaryRouteCooldownTests {
  @Test("an unarmed primary is not cooling")
  func unarmedRouteIsHot() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: clock)

    // when
    let cooling = await cooldown.isCooling()

    // then
    #expect(cooling == false)
  }

  @Test("a long-tier arm cools the route for its window")
  func longArmCools() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: clock)

    // when
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.isCooling() == true)
    #expect(await cooldown.remainingSeconds() == 900)
  }

  @Test("the window expires and the route is probed again")
  func windowExpires() async throws {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)

    // when
    try await clock.sleep(for: .seconds(901))

    // then
    #expect(await cooldown.isCooling() == false)
  }

  @Test("a failed probe re-arms with a doubled window")
  func failedProbeDoubles() async throws {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)
    try await clock.sleep(for: .seconds(901))

    // when
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.remainingSeconds() == 1800)
  }

  @Test("doubling stops at the cap")
  func doublingStopsAtCap() async throws {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, capSeconds: 3600, clock: clock)

    // when
    for _ in 0..<6 {
      await cooldown.arm(persistence: .long, retryAfterSeconds: nil)
      try await clock.sleep(for: .seconds(3601))
    }
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.remainingSeconds() == 3600)
  }

  @Test("a retry-after hint larger than the tier default wins")
  func retryAfterHintWins() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(shortSeconds: 60, longSeconds: 900, clock: clock)

    // when
    await cooldown.arm(persistence: .short, retryAfterSeconds: 120)

    // then
    #expect(await cooldown.remainingSeconds() == 120)
  }

  @Test("a retry-after hint smaller than the tier default is ignored")
  func smallRetryAfterIgnored() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: clock)

    // when
    await cooldown.arm(persistence: .long, retryAfterSeconds: 30)

    // then
    #expect(await cooldown.remainingSeconds() == 900)
  }

  @Test("a success clears the window and resets the doubling")
  func clearResetsDoubling() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)

    // when
    _ = await cooldown.recordSuccess()
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.isCooling() == true)
    #expect(await cooldown.remainingSeconds() == 900)
  }

  @Test("a lapsed window is reported exactly once")
  func expiryIsReportedOnce() async throws {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)

    // when
    try await clock.sleep(for: .seconds(901))

    // then — the window is consumed and dropped in the one hop, so no second success re-reports it
    #expect(await cooldown.recordSuccess() == true)
    #expect(await cooldown.recordSuccess() == false)
  }

  @Test("a success on a live window reports nothing and still drops it")
  func liveWindowReportsNoExpiry() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: clock)
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)

    // when / then — the route answered, so there is nothing to tell the owner about a recovery
    #expect(await cooldown.recordSuccess() == false)
    #expect(await cooldown.isCooling() == false)
  }

  @Test("the actor is usable through its tracking protocol")
  func usableThroughTrackingProtocol() async {
    // given
    let clock = ScriptedClock { _ in }
    let cooldown: any PrimaryRouteCooldownTracking = PrimaryRouteCooldown(
      longSeconds: 900,
      clock: clock
    )

    // when
    await cooldown.arm(persistence: .long, retryAfterSeconds: nil)

    // then
    #expect(await cooldown.isCooling() == true)
  }
}
