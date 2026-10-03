import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite
struct BudgetBreakerTests {
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

  @Test("an included-plan breaker does not notify on default daily caps")
  func includedPlanBreakerSkipsDefaultCaps() async {
    // given
    let breaker = BudgetBreaker(budget: .default, costPolicy: .includedPlan)

    // when
    let shouldNotify = await breaker.shouldNotifyTrip(
      todayTokens: RunBudget.default.dayTokenCeiling,
      todayUSD: RunBudget.default.perDayUSD,
      now: now
    )

    // then
    #expect(!shouldNotify)
  }

  @Test("an explicitly configured subscription token ceiling still notifies once")
  func includedPlanBreakerHonorsExplicitTokenCeiling() async throws {
    // given
    let config = try AppConfig.load(environment: [
      "CLAW_STATE_ROOT": NSTemporaryDirectory(),
      "CLAW_LLM_MODEL": "openai-chatgpt/test-model",
      "CLAW_DAY_TOKEN_CEILING": "100",
    ])
    let breaker = BudgetBreaker(budget: config.budget, costPolicy: .includedPlan)

    // when
    let below = await breaker.shouldNotifyTrip(todayTokens: 99, todayUSD: 0, now: now)
    let first = await breaker.shouldNotifyTrip(todayTokens: 100, todayUSD: 0, now: now)
    let second = await breaker.shouldNotifyTrip(todayTokens: 100, todayUSD: 0, now: now)

    // then
    #expect(!below)
    #expect(first)
    #expect(!second)
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
