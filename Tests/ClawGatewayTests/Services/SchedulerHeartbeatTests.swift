import ClawAgent
import ClawCore
import ClawTestSupport
import ClawWorkspace
import Foundation
import Testing

@testable import ClawGateway

/// A workspace exposing ONLY `HEARTBEAT.md`, scripted per test.
private struct HeartbeatWorkspace: WorkspaceReading {
  let heartbeatFile: LoadedFile

  func load(file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
    file == .heartbeat ? heartbeatFile : .missing
  }

  func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile {
    .missing
  }

  func scanSkills() -> SkillScanResult {
    SkillScanResult(descriptors: [], warnings: [])
  }
}

@Suite struct SchedulerHeartbeatTests {
  /// Mon 2026-07-06 12:00:00 UTC = 14:00 Europe/Berlin — outside the default 22:00-09:00 window.
  private static let daytime = SchedulingTestClock.mondayNoonBerlin
  /// Mon 2026-07-06 21:00:00 UTC = 23:00 Berlin — inside the window, before midnight.
  private static let lateNight = Date(timeIntervalSince1970: 1_783_371_600)
  /// Mon 2026-07-06 03:00:00 UTC = 05:00 Berlin — inside the window, AFTER midnight (crossing).
  private static let earlyMorning = Date(timeIntervalSince1970: 1_783_306_800)

  // swiftlint:disable:next force_unwrapping — a fixed, known-valid identifier; fail loud if not.
  private let berlin = TimeZone(identifier: "Europe/Berlin")!

  private func settings(
    intervalMinutes: Int = 60,
    quietHours: String = "22:00-09:00",
    maxPerDay: Int = 8,
    ownerChatId: Int64 = 777
  ) -> HeartbeatSettings {
    HeartbeatSettings(
      intervalMinutes: intervalMinutes,
      // swiftlint:disable:next force_unwrapping — every call site passes a fixed, valid window.
      quietHours: QuietHours.parse(quietHours)!,
      maxPerDay: maxPerDay,
      ownerChatId: ownerChatId,
      timezone: berlin
    )
  }

  private func state(
    lastHeartbeatAt: Date? = nil,
    countDay: String? = nil,
    count: Int = 0
  ) -> SchedulerState {
    SchedulerState(
      lastTickAt: nil,
      lastMisfireAt: nil,
      lastMisfireSkippedCount: 0,
      lastHeartbeatAt: lastHeartbeatAt,
      heartbeatCountDay: countDay,
      heartbeatCount: count
    )
  }

  private struct Fixture {
    let service: SchedulerService
    let store: ScriptedJobStore
    let runner: FakeTurnRunner
    let audit: RecordingAuditLog
  }

  private func makeFixture(
    heartbeat: HeartbeatSettings?,
    state: SchedulerState,
    file: LoadedFile,
    now: Date,
    firesHeartbeat: Bool = true
  ) -> Fixture {
    // firesHeartbeat == false models the store's overlap skip: fireHeartbeat returns nil because a
    // prior beat's run is still live, so the service must audit an overlap skip rather than fire.
    let heartbeatResult =
      firesHeartbeat
      ? ClaimedFire(
        runId: 901,
        sessionId: 501,
        triggerMessageId: 301,
        ownerChatId: heartbeat?.ownerChatId ?? 777
      )
      : nil
    let store = ScriptedJobStore(
      jobs: [],
      claimResult: nil,
      state: state,
      heartbeatResult: heartbeatResult
    )
    let runner = FakeTurnRunner()
    let audit = RecordingAuditLog()
    let service = SchedulerService(
      jobs: store,
      lanes: SessionLaneRegistry(),
      turns: runner,
      calculator: OccurrenceCalculator(),
      catchUpMaxAge: .seconds(1800),
      heartbeat: heartbeat,
      workspace: HeartbeatWorkspace(heartbeatFile: file),
      audit: audit,
      now: { now },
      clock: ScriptedClock { _ in },
      logger: TestLog.silent
    )
    return Fixture(service: service, store: store, runner: runner, audit: audit)
  }

  private func presentFile(_ text: String) -> LoadedFile {
    LoadedFile(outcome: .present, text: text, graphemeCount: text.count)
  }

  private func skipDecisions(_ fixture: Fixture) -> [String] {
    fixture.audit.events
      .filter { event in event.action == .heartbeatSkipped }
      .map(\.decision)
  }

  @Test func disabledHeartbeatIsStructurallyInert() async throws {
    // given — default OFF; even a due-looking state and a rich file must cost NOTHING
    let fixture = makeFixture(
      heartbeat: nil,
      state: state(lastHeartbeatAt: nil),
      file: presentFile("- check backups"),
      now: Self.daytime
    )

    // when
    await fixture.service.tick()

    // then — zero fires, zero audit rows (spec §12: default OFF ⇒ inert); the effect assertions
    // below prove inertness without pinning how many times the store is read
    #expect(fixture.store.heartbeatFires.isEmpty)
    #expect(fixture.audit.events.isEmpty)
    #expect(await fixture.runner.calls.isEmpty)
  }

  @Test func firesTheTemplateAndEnqueuesLikeAJobFire() async throws {
    // given — enabled, never fired, daytime, under cap, non-empty file
    let fixture = makeFixture(
      heartbeat: settings(),
      state: state(lastHeartbeatAt: nil),
      file: presentFile("- check backups"),
      now: Self.daytime
    )

    // when
    await fixture.service.tick()

    // then — the fixed template wraps the checklist; the day stamp is the BERLIN day
    #expect(
      fixture.store.heartbeatFires == [
        ScriptedJobStore.HeartbeatCall(
          prompt: HeartbeatTemplate.prompt(checklist: "- check backups"),
          ownerChatId: 777,
          day: "2026-07-06"
        )
      ]
    )
    #expect(skipDecisions(fixture).isEmpty)

    // and the fire rode the session lane with the ClaimedFire identity (like a job fire)
    await fixture.runner.waitForCalls(atLeast: 1)
    let call = try #require(await fixture.runner.calls.first)
    #expect(
      call
        == FakeTurnRunner.Call(
          runId: 901,
          sessionId: 501,
          chatId: 777,
          triggerMessageId: 301
        )
    )
  }

  @Test func overlapSkipIsAuditedWithTheOverlapReason() async throws {
    // given — enabled, due, under cap, non-empty file, but a prior beat's run is still live so the
    // store skips the fire (fireHeartbeat returns nil)
    let fixture = makeFixture(
      heartbeat: settings(),
      state: state(lastHeartbeatAt: nil),
      file: presentFile("- check backups"),
      now: Self.daytime,
      firesHeartbeat: false
    )

    // when
    await fixture.service.tick()

    // then — no run enqueued, and the skip is audited with the overlap reason in `decision`,
    // exactly like every other beat skip (not a divergent argsRedacted shape)
    #expect(skipDecisions(fixture) == [HeartbeatSkipReason.overlap.rawValue])
    #expect(await fixture.runner.calls.isEmpty)
  }

  @Test func notDueYetStaysSilentWithNoAudit() async throws {
    // given — fired 30 min ago with a 60-min interval: not due ⇒ no skip row (spec §12)
    let fixture = makeFixture(
      heartbeat: settings(),
      state: state(lastHeartbeatAt: Self.daytime.addingTimeInterval(-1_800)),
      file: presentFile("- check backups"),
      now: Self.daytime
    )

    // when
    await fixture.service.tick()

    // then
    #expect(fixture.store.heartbeatFires.isEmpty)
    #expect(fixture.audit.events.isEmpty)
  }

  @Test(arguments: [lateNight, earlyMorning])
  func quietHoursSkipIsAuditedOnBothSidesOfMidnight(_ instant: Date) async throws {
    // given — 23:00 and 05:00 Berlin both sit inside the midnight-crossing 22:00-09:00 window
    let fixture = makeFixture(
      heartbeat: settings(),
      state: state(lastHeartbeatAt: nil),
      file: presentFile("- check backups"),
      now: instant
    )

    // when
    await fixture.service.tick()

    // then — due but skipped: exactly one audited reason, zero cost
    #expect(fixture.store.heartbeatFires.isEmpty)
    #expect(skipDecisions(fixture) == [HeartbeatSkipReason.quietHours.rawValue])
  }

  @Test func repeatedDueSkipsAuditOncePerEpisode() async throws {
    // given — inside quiet hours, never fired: "due" stays true on EVERY 60 s tick until a
    // fire finally advances last_heartbeat_at. One skip EPISODE must produce one audit row,
    // not one per tick — an 11-hour quiet window is ~660 ticks (spec §12's tick-to-tick
    // quietness; HeartbeatSkipEpisode).
    let fixture = makeFixture(
      heartbeat: settings(),
      state: state(lastHeartbeatAt: nil),
      file: presentFile("- check backups"),
      now: Self.lateNight
    )

    // when — three consecutive ticks, all due, all quiet-hours skips
    await fixture.service.tick()
    await fixture.service.tick()
    await fixture.service.tick()

    // then — one row, not three
    #expect(fixture.store.heartbeatFires.isEmpty)
    #expect(skipDecisions(fixture) == [HeartbeatSkipReason.quietHours.rawValue])
  }

  @Test func dailyCapSkipUsesTheConfiguredZoneDayString() async throws {
    // given — 8 beats already stamped for the BERLIN day 2026-07-06, cap 8
    let fixture = makeFixture(
      heartbeat: settings(maxPerDay: 8),
      state: state(lastHeartbeatAt: nil, countDay: "2026-07-06", count: 8),
      file: presentFile("- check backups"),
      now: Self.daytime
    )

    // when
    await fixture.service.tick()

    // then
    #expect(fixture.store.heartbeatFires.isEmpty)
    #expect(skipDecisions(fixture) == [HeartbeatSkipReason.dailyCap.rawValue])
  }

  @Test func staleDayStampRollsTheCapOver() async throws {
    // given — yesterday's counter is exhausted; today's is implicitly zero (spec §4.3)
    let fixture = makeFixture(
      heartbeat: settings(maxPerDay: 8),
      state: state(lastHeartbeatAt: nil, countDay: "2026-07-05", count: 8),
      file: presentFile("- check backups"),
      now: Self.daytime
    )

    // when
    await fixture.service.tick()

    // then — fires, stamped for the new Berlin day
    #expect(fixture.store.heartbeatFires.count == 1)
    #expect(fixture.store.heartbeatFires.first?.day == "2026-07-06")
    #expect(skipDecisions(fixture).isEmpty)
  }

  @Test func dayBoundaryIsTheConfiguredZoneNotUTC() async throws {
    // given — 23:30 UTC on 07-06 is ALREADY 01:30 Berlin on 07-07; quiet hours are narrowed so
    // only the day-string logic is under test
    let lateUTC = Date(timeIntervalSince1970: 1_783_380_600)
    let fixture = makeFixture(
      heartbeat: settings(quietHours: "03:00-04:00", maxPerDay: 8),
      state: state(lastHeartbeatAt: nil, countDay: "2026-07-07", count: 8),
      file: presentFile("- check backups"),
      now: lateUTC
    )

    // when
    await fixture.service.tick()

    // then — the Berlin day 2026-07-07 matched the stamp: the cap holds even though the UTC
    // day is still 07-06
    #expect(fixture.store.heartbeatFires.isEmpty)
    #expect(skipDecisions(fixture) == [HeartbeatSkipReason.dailyCap.rawValue])
  }

  @Test(arguments: [
    LoadedFile.missing,
    LoadedFile(outcome: .present, text: "", graphemeCount: 0),
    LoadedFile(outcome: .present, text: "  \n\t", graphemeCount: 4),
    LoadedFile(outcome: .overCap, text: "", graphemeCount: 9_999),
    LoadedFile(outcome: .unreadable, text: "", graphemeCount: 0),
  ])
  func unusableFileSkipsBeforeAnyCost(_ file: LoadedFile) async throws {
    // given — missing/empty/whitespace/over-cap/unreadable HEARTBEAT.md
    let fixture = makeFixture(
      heartbeat: settings(),
      state: state(lastHeartbeatAt: nil),
      file: file,
      now: Self.daytime
    )

    // when
    await fixture.service.tick()

    // then — skipped BEFORE fireHeartbeat, so no run row and no LLM call can ever exist
    #expect(fixture.store.heartbeatFires.isEmpty)
    #expect(skipDecisions(fixture) == [HeartbeatSkipReason.emptyFile.rawValue])
    #expect(await fixture.runner.calls.isEmpty)
  }

  @Test func intervalElapsedFiresAgain() async throws {
    // given — last beat exactly one interval ago
    let fixture = makeFixture(
      heartbeat: settings(intervalMinutes: 60),
      state: state(
        lastHeartbeatAt: Self.daytime.addingTimeInterval(-3_600),
        countDay: "2026-07-06",
        count: 1
      ),
      file: presentFile("- check backups"),
      now: Self.daytime
    )

    // when
    await fixture.service.tick()

    // then
    #expect(fixture.store.heartbeatFires.count == 1)
  }
}
