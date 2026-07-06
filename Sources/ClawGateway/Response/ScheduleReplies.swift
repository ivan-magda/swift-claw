import ClawCore
import Foundation

/// Owner-facing copy for the scheduling surface (spec §8/§9): the confirm prompt shows the
/// parked draft VERBATIM and never model-truncated (FR-T5 discipline), and every fire time is
/// rendered in the job's own timezone. Pure rendering — no store or transport knowledge.
public enum ScheduleReplies {
  /// Pinned by the preamble: the confirm prompt previews the next 3 fire times.
  public static let confirmPreviewCount = 3

  static let exampleLine =
    "Example: /schedule every weekday at 07:00 — summarize my unread items"

  public static var parseFailed: String {
    "I couldn't turn that into a schedule. \(exampleLine)"
  }

  public static var emptyList: String {
    "No schedules yet. \(exampleLine)"
  }

  /// Terminal arm failure (the 3a saveFailed pattern): the pending intent was cleared; re-issue.
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
      return "\(row.job.id) · \(row.job.label) · \(row.job.status.rawValue) · "
        + "\(RecurrenceWords.describe(row.job.recurrence)) · \(row.job.timezone) · next \(fire)"
    }.joined(separator: "\n")
  }

  public static func notFound(id: Int64) -> String {
    "No schedule with id \(id). See /schedule list."
  }

  /// Terminal verb failure after the update was already claimed: nothing changed; re-issue.
  public static let verbFailed = "Couldn't update the schedule. Nothing changed. Try again."

  public static let pauseUsage = "Usage: /pause <id> — see /schedule list"
  public static let resumeUsage = "Usage: /resume <id> — see /schedule list"
  public static let runNowUsage = "Usage: /runnow <id> — see /schedule list"
  public static let cancelUsage = "Usage: /cancel <id> — see /schedule list"

  public static func paused(job: ScheduledJob) -> String {
    "Paused schedule \(job.id) · «\(job.label)». Resume with /resume \(job.id)."
  }

  public static func resumed(job: ScheduledJob) -> String {
    guard let next = job.nextOccurrence else {
      return "Resumed schedule \(job.id) · «\(job.label)» — nothing left to fire."
    }
    return "Resumed schedule \(job.id) · «\(job.label)» — next fire "
      + "\(fireTime(next, timezoneId: job.timezone))."
  }

  public static func cancelled(job: ScheduledJob) -> String {
    "Cancelled schedule \(job.id) · «\(job.label)». It will not fire again; "
      + "an in-flight run finishes on its own."
  }

  public static func runningNow(id: Int64) -> String {
    "Running schedule \(id) now — the result will arrive like any scheduled delivery."
  }

  /// `yyyy-MM-dd HH:mm` in the given zone — deterministic and locale-free (the ISO8601 format
  /// styles force seconds; owners schedule in minutes).
  static func fireTime(_ date: Date, timezoneId: String) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timezoneId) ?? .gmt  // id was validated upstream
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(
      format: "%04d-%02d-%02d %02d:%02d",
      parts.year ?? 0,
      parts.month ?? 0,
      parts.day ?? 0,
      parts.hour ?? 0,
      parts.minute ?? 0
    )
  }
}
