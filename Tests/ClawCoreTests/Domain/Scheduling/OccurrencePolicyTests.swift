import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore

@Suite struct OccurrencePolicyTests {
  private let policy = OccurrencePolicy()
  private let utc = TimeZone(identifier: "UTC")

  /// 2026-07-06 12:00:00 UTC — a fixed, DST-free reference instant (the same instant as
  /// `SchedulingTestClock.mondayNoonBerlin`, read here as plain UTC noon).
  private let noon = SchedulingTestClock.mondayNoonBerlin

  private func everyTenMinutesRule() throws -> Calendar.RecurrenceRule {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(utc)
    return Calendar.RecurrenceRule(calendar: calendar, frequency: .minutely, interval: 10)
  }

  private func validated(
    recurrence: RecurrenceEnvelope?,
    firstOccurrence: Date,
    timezone: String = "UTC"
  ) -> ValidatedSchedule {
    ValidatedSchedule(
      label: "standup",
      prompt: "post the standup summary",
      recurrence: recurrence,
      timezone: timezone,
      firstOccurrence: firstOccurrence
    )
  }

  private func job(
    recurrence: RecurrenceEnvelope?,
    nextOccurrence: Date?,
    timezone: String = "UTC"
  ) -> ScheduledJob {
    ScheduledJob(
      id: 1,
      ownerChatId: 7,
      label: "standup",
      prompt: "post the standup summary",
      recurrence: recurrence,
      timezone: timezone,
      nextOccurrence: nextOccurrence,
      lastFiredAt: nil,
      status: .paused,
      sessionId: nil,
      createdTs: noon.addingTimeInterval(-86_400),
      updatedTs: noon
    )
  }

  private func envelope() throws -> RecurrenceEnvelope {
    RecurrenceEnvelope(
      schemaVersion: RecurrenceEnvelope.currentSchemaVersion,
      rule: try everyTenMinutesRule()
    )
  }

  // MARK: - confirmPreview

  @Test func oneShotPreviewIsItsSingleInstant() {
    // given
    let schedule = validated(recurrence: nil, firstOccurrence: noon.addingTimeInterval(3_600))

    // when
    let preview = policy.confirmPreview(for: schedule, from: noon, limit: 3)

    // then
    #expect(preview == [schedule.firstOccurrence])
  }

  @Test func unknownTimezonePreviewFallsBackToTheFirstOccurrence() throws {
    // given — fail-safe, matching the arm fallback: never an empty preview for a valid draft
    let schedule = validated(
      recurrence: try envelope(),
      firstOccurrence: noon.addingTimeInterval(600),
      timezone: "Not/AZone"
    )

    // when
    let preview = policy.confirmPreview(for: schedule, from: noon, limit: 3)

    // then
    #expect(preview == [schedule.firstOccurrence])
  }

  @Test func recurringPreviewSeedsThePhaseFromTheValidationClock() throws {
    // given
    let schedule = validated(
      recurrence: try envelope(),
      firstOccurrence: noon.addingTimeInterval(600)
    )

    // when — the SAME nowDate that validation used seeds the calculator
    let preview = policy.confirmPreview(for: schedule, from: noon, limit: 3)

    // then — the preview's first entry IS the parked firstOccurrence, phase noon + k·10min
    #expect(preview.count == 3)
    #expect(preview[0] == noon.addingTimeInterval(600))
    #expect(preview[1] == noon.addingTimeInterval(1_200))
    #expect(preview[2] == noon.addingTimeInterval(1_800))
  }

  // MARK: - armOccurrence

  @Test func oneShotStillAheadArmsItsInstant() {
    // given
    let schedule = validated(recurrence: nil, firstOccurrence: noon.addingTimeInterval(3_600))

    // when / then
    #expect(policy.armOccurrence(for: schedule, at: noon) == schedule.firstOccurrence)
  }

  @Test func oneShotWhoseInstantPassedArmsNothing() {
    // given — a draft confirmed long after its preview cannot arm an already-past occurrence
    let schedule = validated(recurrence: nil, firstOccurrence: noon.addingTimeInterval(-60))

    // when / then
    #expect(policy.armOccurrence(for: schedule, at: noon) == nil)
  }

  @Test func lateConfirmKeepsThePreviewedPhaseAndSkipsPastOccurrences() throws {
    // given — parked at noon+10min, confirmed 25 minutes later
    let schedule = validated(
      recurrence: try envelope(),
      firstOccurrence: noon.addingTimeInterval(600)
    )
    let confirmTime = noon.addingTimeInterval(1_500)

    // when — anchor = parked firstOccurrence (phase continuity), after = confirm-time now
    let armed = policy.armOccurrence(for: schedule, at: confirmTime)

    // then — next on the previewed chain strictly after confirm time: noon+30min, not noon+35min
    #expect(armed == noon.addingTimeInterval(1_800))
  }

  // MARK: - resumeOccurrence

  @Test func resumedOneShotStillAheadKeepsItsInstant() {
    // given
    let paused = job(recurrence: nil, nextOccurrence: noon.addingTimeInterval(3_600))

    // when / then
    #expect(policy.resumeOccurrence(for: paused, from: noon) == paused.nextOccurrence)
  }

  @Test func resumedOneShotWhoseInstantPassedHasNothingLeftToFire() {
    // given
    let paused = job(recurrence: nil, nextOccurrence: noon.addingTimeInterval(-60))

    // when / then
    #expect(policy.resumeOccurrence(for: paused, from: noon) == nil)
  }

  @Test func resumeSkipsThePausedWindowButKeepsThePhase() throws {
    // given — stale stored next at noon, resumed 25 minutes later
    let paused = job(recurrence: try envelope(), nextOccurrence: noon)

    // when — anchor = the stale stored next; after = now (pause = "be quiet", never catch up)
    let resumed = policy.resumeOccurrence(for: paused, from: noon.addingTimeInterval(1_500))

    // then — next on the armed chain after the window: noon+30min
    #expect(resumed == noon.addingTimeInterval(1_800))
  }

  // MARK: - advance / coalescedFireTime / missedOccurrenceCount

  @Test func advanceYieldsTheNextChainOccurrenceAndNilForOneShots() throws {
    // given
    let recurring = job(recurrence: try envelope(), nextOccurrence: noon)
    let oneShot = job(recurrence: nil, nextOccurrence: noon)
    let timezone = try #require(utc)

    // when / then — a one-shot has no next (→ COMPLETED); recurring stays on the due chain
    #expect(
      policy.advance(
        for: recurring,
        timezone: timezone,
        anchor: noon,
        after: noon.addingTimeInterval(90)
      )
        == noon.addingTimeInterval(600)
    )
    #expect(policy.advance(for: oneShot, timezone: timezone, anchor: noon, after: noon) == nil)
  }

  @Test func coalesceFiresOnceAtTheLatestMissedOccurrence() throws {
    // given — due at noon, tick arrives 25 minutes late: noon, +10, +20 were missed
    let recurring = job(recurrence: try envelope(), nextOccurrence: noon)
    let timezone = try #require(utc)

    // when
    let fireAt = policy.coalescedFireTime(
      for: recurring,
      timezone: timezone,
      due: noon,
      atOrBefore: noon.addingTimeInterval(1_500)
    )

    // then — the latest missed occurrence ≤ now, still on the due chain (§5.3)
    #expect(fireAt == noon.addingTimeInterval(1_200))
  }

  @Test func coalesceForAOneShotIsItsStoredDue() throws {
    // given
    let oneShot = job(recurrence: nil, nextOccurrence: noon)
    let timezone = try #require(utc)

    // when / then — a one-shot has exactly one occurrence: the stored one
    #expect(
      policy.coalescedFireTime(
        for: oneShot,
        timezone: timezone,
        due: noon,
        atOrBefore: noon.addingTimeInterval(1_500)
      )
        == noon
    )
  }

  @Test func missedCountCoversTheWindowAndIsOneForOneShots() throws {
    // given
    let recurring = job(recurrence: try envelope(), nextOccurrence: noon)
    let oneShot = job(recurrence: nil, nextOccurrence: noon)
    let timezone = try #require(utc)
    let tickTime = noon.addingTimeInterval(1_500)

    // when / then — noon, +10, +20 missed ⇒ 3; a one-shot misfire is always exactly 1
    #expect(
      policy.missedOccurrenceCount(
        for: recurring,
        timezone: timezone,
        due: noon,
        atOrBefore: tickTime,
        limit: 1_000
      )
        == 3
    )
    #expect(
      policy.missedOccurrenceCount(
        for: oneShot,
        timezone: timezone,
        due: noon,
        atOrBefore: tickTime,
        limit: 1_000
      )
        == 1
    )
  }
}
