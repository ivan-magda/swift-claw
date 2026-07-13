import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ScheduleCommandStoreTests {
  private let fixedNow = SchedulingTestClock.mondayNoonBerlin

  private func makeQueue() throws -> DatabaseQueue {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return queue
  }

  private func makeNewJob() throws -> NewScheduledJob {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
    let rule = Calendar.RecurrenceRule(
      calendar: calendar,
      frequency: .daily,
      hours: [7],
      minutes: [0],
      seconds: [0]
    )
    return NewScheduledJob(
      ownerChatId: 42,
      label: "morning digest",
      prompt: "Summarize my unread items",
      recurrence: RecurrenceEnvelope(schemaVersion: 1, rule: rule),
      timezone: "Europe/Berlin",
      nextOccurrence: SchedulingTestClock.tuesdaySevenBerlin
    )
  }

  @Test func applyArmClaimsInsertsAndAuditsInOneWrite() throws {
    // given
    let queue = try makeQueue()
    let store = ScheduleCommandStoreGRDB(writer: queue)

    // when
    let result = try store.applyArm(updateId: 900, job: makeNewJob(), now: fixedNow)

    // then — claim + job row + jobCreated audit landed together
    #expect(result.newlyClaimed)
    let job = try #require(result.job)
    #expect(job.label == "morning digest")
    #expect(job.ownerChatId == 42)
    #expect(job.status == .active)
    #expect(job.nextOccurrence == SchedulingTestClock.tuesdaySevenBerlin)
    let jobCount = try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduled_jobs") ?? -1
    }
    let auditCount = try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM audit_events WHERE action = '\(AuditAction.jobCreated.rawValue)'"
      ) ?? -1
    }
    #expect(jobCount == 1)
    #expect(auditCount == 1)
  }

  @Test func replayedUpdateIdCreatesNothing() throws {
    // given — the first "yes" armed the job
    let queue = try makeQueue()
    let store = ScheduleCommandStoreGRDB(writer: queue)
    _ = try store.applyArm(updateId: 900, job: makeNewJob(), now: fixedNow)

    // when — Telegram redelivers the same update
    let replay = try store.applyArm(updateId: 900, job: makeNewJob(), now: fixedNow)

    // then — idempotent via the update_id claim (spec §8/§16 case 7)
    #expect(replay.newlyClaimed == false)
    #expect(replay.job == nil)
    let jobCount = try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduled_jobs") ?? -1
    }
    #expect(jobCount == 1)
  }
}
