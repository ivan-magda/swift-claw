import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct BudgetBreakerTests {
  /// A fixed instant so the per-UTC-day latch is deterministic across calls.
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("the daily-USD trip notifies once, then latches for the rest of the UTC day")
  func notifiesOnceWhenDailyUSDCapIsTripped() async {
    // given
    let breaker = BudgetBreaker(budget: .default)

    // when
    let first = await breaker.shouldNotifyTrip(todayTokens: 0, todayUSD: 10.0, now: now)
    let second = await breaker.shouldNotifyTrip(todayTokens: 0, todayUSD: 10.0, now: now)

    // then
    #expect(first)
    #expect(!second)
  }

  @Test("the latch resets on the next UTC day, so the trip notifies again")
  func notifiesAgainAfterUTCDayRollover() async {
    // given
    let breaker = BudgetBreaker(budget: .default)
    let nextDay = now.addingTimeInterval(24 * 60 * 60)

    // when
    let today = await breaker.shouldNotifyTrip(todayTokens: 0, todayUSD: 10.0, now: now)
    let sameDayAgain = await breaker.shouldNotifyTrip(todayTokens: 0, todayUSD: 10.0, now: now)
    let tomorrow = await breaker.shouldNotifyTrip(todayTokens: 0, todayUSD: 10.0, now: nextDay)

    // then
    #expect(today)
    #expect(!sameDayAgain)
    #expect(tomorrow)
  }

  @Test("no trip just below the daily USD cap")
  func doesNotNotifyBelowTheCap() async {
    // given
    let breaker = BudgetBreaker(budget: .default)

    // when
    let shouldNotify = await breaker.shouldNotifyTrip(todayTokens: 0, todayUSD: 9.99, now: now)

    // then
    #expect(!shouldNotify)
  }

  @Test("the token ceiling trips the breaker too, even with zero known spend")
  func tripsOnTheTokenCeilingToo() async {
    // given
    let breaker = BudgetBreaker(budget: .default)

    // when
    let shouldNotify = await breaker.shouldNotifyTrip(todayTokens: 666_666, todayUSD: 0, now: now)

    // then
    #expect(shouldNotify)
  }

  @Test("the proactive trip DM latches once per UTC day and resets on rollover")
  func proactiveTripNotifiesOncePerUTCDay() async {
    // given
    let breaker = BudgetBreaker(budget: .default)
    let nextDay = now.addingTimeInterval(24 * 60 * 60)

    // when
    let first = await breaker.shouldNotifyProactiveTrip(now: now)
    let second = await breaker.shouldNotifyProactiveTrip(now: now)
    let tomorrow = await breaker.shouldNotifyProactiveTrip(now: nextDay)

    // then
    #expect(first)
    #expect(!second)
    #expect(tomorrow)
  }

  @Test("an included-plan breaker never DMs on the USD cap but still trips on the token ceiling")
  func includedPlanBreakerSkipsUSDButNotTheTokenCeiling() async {
    // given — a subscription daemon whose day already rang up API-billed dollars over the cap
    let breaker = BudgetBreaker(budget: .default, costPolicy: .includedPlan)

    // when — the USD figure alone would DM under `metered`
    let usdOnly = await breaker.shouldNotifyTrip(todayTokens: 0, todayUSD: 10.0, now: now)
    // then — a subscription cap DM must not fire off dollars that are not a gate
    #expect(!usdOnly)

    // when — the hard token ceiling is met
    let tokenTrip = await breaker.shouldNotifyTrip(todayTokens: 666_666, todayUSD: 0, now: now)
    // then — the global token breaker still DMs
    #expect(tokenTrip)
  }

  @Test("the proactive latch is independent of the global daily latch")
  func proactiveLatchIsIndependentOfTheGlobalOne() async {
    // given
    let breaker = BudgetBreaker(budget: .default)

    // when — the global cap trips and DMs first; the proactive trip must still DM the same day
    let globalNotify = await breaker.shouldNotifyTrip(todayTokens: 0, todayUSD: 10.0, now: now)
    let proactiveNotify = await breaker.shouldNotifyProactiveTrip(now: now)

    // then
    #expect(globalNotify)
    #expect(proactiveNotify)
  }
}
