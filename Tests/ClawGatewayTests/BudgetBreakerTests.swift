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
}
