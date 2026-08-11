import ClawCore
import ClawData
import ClawGateway
import Foundation
import GRDB
import Testing

@testable import clawd

@Suite struct DoctorHealthStoreReadTests {
  @Test func failedStoreReadsProduceFailedRows() throws {
    // given
    let fixture = try fixture(migrated: false)
    defer { try? FileManager.default.removeItem(at: fixture.config.stateRoot) }

    // when
    let rows = rows(stores: fixture.stores, config: fixture.config)

    // then
    let storeBackedKeys = [
      "llm.last_success",
      "llm.consecutive_failures",
      "runs.in_flight",
      "runs.oldest_age_s",
      "runs.last_FAILED",
      "context.last_prompt_tokens",
      "spend.today_usd",
      "spend.today_tokens",
      "spend.remaining_day_usd",
      "spend.cost_source_mix",
      "scheduler.last_tick_at",
      "scheduler.due_count",
      "scheduler.last_misfire",
      "spend.proactive_today_usd",
      "heartbeat.last",
      "heartbeat.today",
      "approvals.pending",
      "approvals.oldest_age_s",
    ]
    for key in storeBackedKeys {
      let row = rows[key]
      #expect(row?.ok == false)
      #expect(row?.value == "unreadable (db read failed)")
    }
  }

  @Test func successfulEmptyReadsKeepZeroAndEmptyRendering() throws {
    // given
    let fixture = try fixture(migrated: true)
    defer { try? FileManager.default.removeItem(at: fixture.config.stateRoot) }

    // when
    let rows = rows(stores: fixture.stores, config: fixture.config)

    // then
    let expectedValues = [
      "llm.last_success": "never",
      "llm.consecutive_failures": "0",
      "runs.in_flight": "0",
      "runs.oldest_age_s": "none",
      "runs.last_FAILED": "none",
      "context.last_prompt_tokens": "none",
      "spend.today_usd": USD.precise(0),
      "spend.today_tokens": "0",
      "spend.remaining_day_usd": USD.display(fixture.config.budget.perDayUSD),
      "spend.cost_source_mix": "none",
      "scheduler.last_tick_at": "never",
      "scheduler.due_count": "0",
      "scheduler.last_misfire": "none",
      "spend.proactive_today_usd":
        "0.00/\(USD.display(fixture.config.budget.proactivePerDayUSD))",
      "heartbeat.last": "never",
      "heartbeat.today": "0/\(fixture.config.heartbeatMaxPerDay)",
      "approvals.pending": "0",
      "approvals.oldest_age_s": "none",
    ]
    for (key, value) in expectedValues {
      let row = rows[key]
      #expect(row?.ok == true)
      #expect(row?.value == value)
    }
  }
}

private extension DoctorHealthStoreReadTests {
  func fixture(migrated: Bool) throws -> (stores: ClawStores, config: AppConfig) {
    let config = try AppConfig.load(environment: CompositionAcceptanceHarness.validEnv())
    try FileManager.default.createDirectory(
      at: EnvironmentLoader.workspaceRoot(config: config)
        .appendingPathComponent(WorkspaceSkills.directoryName),
      withIntermediateDirectories: true
    )
    let writer = try ClawDatabase.makeInMemoryQueue()
    if migrated {
      try ClawDatabase.migrate(writer)
    }
    return (stores(writer: writer), config)
  }

  func stores(writer: any DatabaseWriter) -> ClawStores {
    ClawStores(
      allowlist: AllowlistStoreGRDB(writer: writer),
      processed: ProcessedUpdateStoreGRDB(writer: writer),
      commands: CommandStoreGRDB(writer: writer),
      cursor: UpdateCursorStoreGRDB(writer: writer),
      sessionMessages: SessionMessageStoreGRDB(writer: writer),
      runs: RunStoreGRDB(writer: writer),
      usage: UsageStoreGRDB(writer: writer),
      outbox: OutboxStoreGRDB(writer: writer),
      audit: AuditLogGRDB(writer: writer),
      memory: MemoryStoreGRDB(writer: writer),
      memoryCommands: MemoryCommandStoreGRDB(writer: writer),
      retriever: RetrieverGRDB(writer: writer),
      scheduledJobs: ScheduledJobStoreGRDB(writer: writer),
      scheduleCommands: ScheduleCommandStoreGRDB(writer: writer),
      approvals: ApprovalStoreGRDB(writer: writer)
    )
  }

  func rows(stores: ClawStores, config: AppConfig) -> [String: DoctorReport.Check] {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let inputs = DoctorHealth.inputs(
      stores: stores,
      config: config,
      now: now,
      routeHealth: LLMRouteHealth(
        primaryReference: config.llm.route.configuredReference,
        fallbackReference: nil,
        cooldown: .unobservable
      )
    )
    let checks =
      HealthRowsBuilder.checks(inputs)
      + DoctorHealth.schedulerChecks(stores: stores, config: config, now: now)
      + DoctorHealth.approvalChecks(stores: stores, config: config, now: now)
    return Dictionary(
      checks.map { check in
        (check.key, check)
      },
      uniquingKeysWith: { first, _ in
        first
      }
    )
  }
}
