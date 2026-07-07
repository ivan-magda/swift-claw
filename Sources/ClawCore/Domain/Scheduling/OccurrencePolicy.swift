import Foundation

/// Use-case anchoring policy over `OccurrenceCalculator` (spec §5.3/§5.4/§8): each method names
/// one moment the system asks "what fires next / what fires now" and pins that moment's anchor
/// and cutoff, so the confirm preview, arm, resume, tick advance, and misfire coalesce can never
/// drift apart. The calculator answers "which instants match the rule"; this type answers "which
/// of them this use case wants".
public struct OccurrencePolicy: Sendable {
  private let calculator: OccurrenceCalculator

  public init(calculator: OccurrenceCalculator = OccurrenceCalculator()) {
    self.calculator = calculator
  }

  /// The confirm preview's fire times. The SAME `nowDate` that validation used seeds the
  /// calculator, so the preview's first entry IS the parked `firstOccurrence`.
  public func confirmPreview(
    for validated: ValidatedSchedule,
    from nowDate: Date,
    limit: Int
  ) -> [Date] {
    guard
      let envelope = validated.recurrence,
      let timezone = TimeZone(identifier: validated.timezone)
    else {
      return [validated.firstOccurrence]
    }
    return calculator.occurrences(
      rule: envelope.rule,
      timezone: timezone,
      anchor: nowDate,
      after: nowDate,
      limit: limit
    )
  }

  /// The fire time to arm with. Anchoring on the parked `firstOccurrence` (not arm-time `now`)
  /// keeps the previewed everyNMinutes phase intact (preamble deviation #1: phase-continuous
  /// from preview through every fire) — mirroring `resumeOccurrence`, which anchors on the
  /// stored occurrence rather than `now` for the same reason. `after: nowDate` still does the
  /// M1 job: it skips any occurrence already past by confirm time, so a draft confirmed long
  /// after its preview can't arm an already-past occurrence (a one-shot would silently misfire
  /// to COMPLETED; a recurring one would fire immediately). This re-runs the SAME parked rule —
  /// not a re-parse (§8): label/prompt/rule/timezone are still the parked draft's. Returns nil
  /// when nothing valid remains to arm: a one-shot whose instant has passed, or (pathological)
  /// a rule with no upcoming occurrence.
  public func armOccurrence(for validated: ValidatedSchedule, at nowDate: Date) -> Date? {
    guard let envelope = validated.recurrence else {
      return validated.firstOccurrence > nowDate ? validated.firstOccurrence : nil
    }

    guard let timezone = TimeZone(identifier: validated.timezone) else {
      return validated.firstOccurrence > nowDate ? validated.firstOccurrence : nil
    }

    return calculator.occurrences(
      rule: envelope.rule,
      timezone: timezone,
      anchor: validated.firstOccurrence,
      after: nowDate,
      limit: 1
    ).first
  }

  /// Resume's next fire: recurring ⇒ the calculator's next occurrence after now; one-shot ⇒ its
  /// stored instant if still ahead, else nothing left to fire. Anchor = the stale stored next
  /// (pause leaves next_occurrence untouched): the recompute stays on the armed chain —
  /// everyNMinutes keeps its phase — while `after: nowDate` skips everything inside the paused
  /// window (§5.4: pause = "be quiet", never catch up).
  public func resumeOccurrence(for job: ScheduledJob, from nowDate: Date) -> Date? {
    guard
      let envelope = job.recurrence,
      let timezone = TimeZone(identifier: job.timezone)
    else {
      guard let instant = job.nextOccurrence, instant > nowDate else {
        return nil
      }
      return instant
    }
    return calculator.occurrences(
      rule: envelope.rule,
      timezone: timezone,
      anchor: job.nextOccurrence ?? job.createdTs,
      after: nowDate,
      limit: 1
    ).first
  }

  /// The advanced next_occurrence after a fire or skip: strictly after `after`; nil for a
  /// one-shot (→ COMPLETED). `anchor` is the occurrence being advanced from (the claimed or
  /// skipped due) — advances stay on the armed chain, so /schedule's confirm preview can never
  /// disagree with actual fires.
  public func advance(
    for job: ScheduledJob,
    timezone: TimeZone,
    anchor: Date,
    after: Date
  ) -> Date? {
    job.recurrence.flatMap { envelope in
      calculator.occurrences(
        rule: envelope.rule,
        timezone: timezone,
        anchor: anchor,
        after: after,
        limit: 1
      ).first
    }
  }

  /// Coalesce (§5.3): N missed occurrences inside the catch-up window fire ONCE, at the latest
  /// missed occurrence ≤ `atOrBefore`; the claim's CAS still matches the stored due. Anchor =
  /// the stored due: every advance stays on the chain the confirm preview showed (for
  /// everyNMinutes the phase is due + k·N; time-of-day rules are anchor-inert). A one-shot has
  /// exactly one occurrence — the stored one.
  public func coalescedFireTime(
    for job: ScheduledJob,
    timezone: TimeZone,
    due: Date,
    atOrBefore: Date
  ) -> Date {
    guard let envelope = job.recurrence else {
      return due
    }
    return calculator.latestOccurrence(
      rule: envelope.rule,
      timezone: timezone,
      anchor: due,
      after: due.addingTimeInterval(-1),
      atOrBefore: atOrBefore
    ) ?? due
  }

  /// How many occurrences a skip-misfire jumped over (observability only — the count feeds the
  /// `jobMisfire` audit details, never control flow). `limit` caps the scan so a months-old due
  /// date cannot enumerate unbounded dates.
  public func missedOccurrenceCount(
    for job: ScheduledJob,
    timezone: TimeZone,
    due: Date,
    atOrBefore: Date,
    limit: Int
  ) -> Int {
    job.recurrence.map { envelope in
      calculator.occurrences(
        rule: envelope.rule,
        timezone: timezone,
        anchor: due,
        after: due.addingTimeInterval(-1),
        limit: limit
      ).filter { occurrence in
        occurrence <= atOrBefore
      }.count
    } ?? 1
  }
}
