import ClawCore
import Foundation

/// Owner-facing copy for the scheduling surface: the confirm prompt shows the parked draft
/// VERBATIM and never model-truncated, and every fire time is rendered in the job's own
/// timezone. Pure rendering — no store or transport knowledge.
public enum ScheduleReplies {
  /// The confirm prompt previews the next 3 fire times.
  public static let confirmPreviewCount = 3

  static let exampleLine =
    "Example: /schedule every weekday at 07:00, summarize my unread items"

  public static var parseFailed: String {
    "I couldn't turn that into a schedule. \(exampleLine)"
  }

  // The provider-failure copy for a `/schedule` parse delegates to `Degradation` so a scheduled
  // parse and an interactive turn hand the owner byte-identical guidance for the same failure — the
  // auth sentence names the exact recovery command, while access and quota deliberately do not.

  /// A `/schedule` parse that could not reach a usable model (terminal reject, brownout, deadline).
  public static var providerUnavailable: String { Degradation.providerUnavailable }

  /// The credential is gone or refused; names `clawd auth login` as the exact recovery.
  public static var authenticationRequired: String { Degradation.authenticationRequired }

  /// The plan/account cannot use the requested route or model; does not tell the owner to log in.
  public static var accessDenied: String { Degradation.accessDenied }

  /// A clean throttle; says to retry after the provider's hint or the plan reset, never to log in.
  public static func quotaLimited(retryAfterSeconds: Int?) -> String {
    Degradation.quotaLimited(retryAfterSeconds: retryAfterSeconds)
  }

  /// The owner reply for a `/schedule` parse that failed at the provider. Typed failures earn their
  /// own actionable guidance; every other result falls back to the generic unavailable copy (the
  /// router only routes provider-failure results here, so the fallback is never reached in practice).
  public static func providerFailure(_ result: ScheduleDraftParseResult) -> String {
    switch result {
    case .authenticationRequired:
      return authenticationRequired
    case .accessDenied:
      return accessDenied
    case .quotaLimited(let retryAfterSeconds):
      return quotaLimited(retryAfterSeconds: retryAfterSeconds)
    case .providerUnavailable, .draft, .unparseable, .budgetDenied:
      return providerUnavailable
    }
  }

  public static var emptyList: String {
    "No schedules yet. \(exampleLine)"
  }

  /// Terminal arm failure: the pending intent was cleared; re-issue.
  public static let armFailed =
    "Couldn't arm the schedule. Nothing was created. Run /schedule again."

  /// A parked one-shot confirmed after its instant already passed — nothing left to arm.
  public static let armExpired =
    "That schedule's time has already passed. Send /schedule again to set a new one."

  public static func confirmPrompt(schedule: ValidatedSchedule, nextFires: [Date]) -> String {
    var lines = [
      "Arm this schedule?",
      "label: «\(schedule.label)»",
      "task: «\(schedule.prompt)»",
      "when: \(schedule.recurrenceInWords)",
      "timezone: \(schedule.timezone)",
      nextFires.count == 1 ? "next fire:" : "next \(nextFires.count) fires:",
    ]

    for fire in nextFires {
      lines.append("  \(fireTime(fire, timezoneId: schedule.timezone))")
    }
    lines.append("Reply yes to arm, no to cancel.")

    return lines.joined(separator: "\n")
  }

  /// `job` is nil only if a `ScheduleCommandStore` violates its newlyClaimed-implies-job
  /// contract; the ack degrades instead of crashing the router (the MemoryReplies.saved pattern).
  public static func armed(job: ScheduledJob?) -> String {
    guard let job else {
      return "Armed."
    }

    var text = "Armed schedule \(job.id) · «\(job.label)»"
    if let next = job.nextOccurrence {
      text += " · next fire \(fireTime(next, timezoneId: job.timezone))"
    }

    return text + "."
  }

  /// One `/schedule list` row: `id · label · status · recurrence-in-words · tz · next fire`.
  public static func listLines(_ rows: [(job: ScheduledJob, nextFire: Date?)]) -> String {
    rows.map { row in
      let fire =
        row.nextFire.map { date in
          fireTime(date, timezoneId: row.job.timezone)
        } ?? "—"
      return """
        \(row.job.id) · \(row.job.label) · \(row.job.status.rawValue) · \
        \(RecurrenceWords.describe(row.job.recurrence)) · \(row.job.timezone) · next \(fire)
        """
    }.joined(separator: "\n")
  }

  public static func notFound(id: Int64) -> String {
    "No schedule with id \(id). See /schedule list."
  }

  /// Terminal verb failure after the update was already claimed: nothing changed; re-issue.
  public static let verbFailed = "Couldn't update the schedule. Nothing changed. Try again."

  public static let pauseUsage = "Usage: /pause <id>. See /schedule list"
  public static let resumeUsage = "Usage: /resume <id>. See /schedule list"
  public static let runNowUsage = "Usage: /runnow <id>. See /schedule list"
  public static let cancelUsage = "Usage: /cancel <id>. See /schedule list"

  public static func paused(job: ScheduledJob) -> String {
    "Paused schedule \(job.id) · «\(job.label)». Resume with /resume \(job.id)."
  }

  public static func resumed(job: ScheduledJob) -> String {
    guard let next = job.nextOccurrence else {
      return "Resumed schedule \(job.id) · «\(job.label)». Nothing left to fire."
    }
    return """
      Resumed schedule \(job.id) · «\(job.label)». Next fire \
      \(fireTime(next, timezoneId: job.timezone)).
      """
  }

  public static func cancelled(job: ScheduledJob) -> String {
    """
    Cancelled schedule \(job.id) · «\(job.label)». It will not fire again; \
    an in-flight run finishes on its own.
    """
  }

  public static func runningNow(id: Int64) -> String {
    "Running schedule \(id) now. You'll get the result like any scheduled delivery."
  }

  /// `/runnow` on a job whose previous run hasn't finished: the fire is skipped, not failed.
  public static func alreadyRunning(id: Int64) -> String {
    "Schedule \(id) already has a run in progress. Wait for it to finish, then try again."
  }

  static func fireTime(_ date: Date, timezoneId: String) -> String {
    let zone = TimeZone(identifier: timezoneId) ?? .gmt  // id was validated upstream
    return date.wallClockMinute(in: zone)
  }
}
