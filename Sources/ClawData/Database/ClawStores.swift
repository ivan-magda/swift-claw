import ClawCore

/// Bundle of the stores as ClawCore protocol types — lets `clawd` wire persistence without
/// importing GRDB. The backing DatabasePool is retained by the stores.
public struct ClawStores: Sendable {
  public let allowlist: any AllowlistStore
  public let processed: any ProcessedUpdateStore
  public let commands: any CommandStore
  public let cursor: any UpdateCursorStore

  public let sessionMessages: any SessionMessageStore
  public let runs: any RunStore
  public let usage: any UsageStore
  public let outbox: any OutboxStore
  public let audit: any AuditLog

  public let memory: any MemoryStore
  public let memoryCommands: any MemoryCommandStore
  public let retriever: any Retriever

  public let scheduledJobs: any ScheduledJobStore
  public let scheduleCommands: any ScheduleCommandStore

  public let approvals: any ApprovalStore

  public init(
    allowlist: any AllowlistStore,
    processed: any ProcessedUpdateStore,
    commands: any CommandStore,
    cursor: any UpdateCursorStore,
    sessionMessages: any SessionMessageStore,
    runs: any RunStore,
    usage: any UsageStore,
    outbox: any OutboxStore,
    audit: any AuditLog,
    memory: any MemoryStore,
    memoryCommands: any MemoryCommandStore,
    retriever: any Retriever,
    scheduledJobs: any ScheduledJobStore,
    scheduleCommands: any ScheduleCommandStore,
    approvals: any ApprovalStore
  ) {
    self.allowlist = allowlist
    self.processed = processed
    self.commands = commands
    self.cursor = cursor

    self.sessionMessages = sessionMessages
    self.runs = runs
    self.usage = usage
    self.outbox = outbox
    self.audit = audit

    self.memory = memory
    self.memoryCommands = memoryCommands
    self.retriever = retriever

    self.scheduledJobs = scheduledJobs
    self.scheduleCommands = scheduleCommands

    self.approvals = approvals
  }
}

extension ClawDatabase {
  /// Opens the WAL pool, runs migrations, and hands back the protocol-typed stores.
  public static func openStores(path: String) throws -> ClawStores {
    let pool = try makePool(path: path)
    try migrate(pool)
    return ClawStores(
      allowlist: AllowlistStoreGRDB(writer: pool),
      processed: ProcessedUpdateStoreGRDB(writer: pool),
      commands: CommandStoreGRDB(writer: pool),
      cursor: UpdateCursorStoreGRDB(writer: pool),
      sessionMessages: SessionMessageStoreGRDB(writer: pool),
      runs: RunStoreGRDB(writer: pool),
      usage: UsageStoreGRDB(writer: pool),
      outbox: OutboxStoreGRDB(writer: pool),
      audit: AuditLogGRDB(writer: pool),
      memory: MemoryStoreGRDB(writer: pool),
      memoryCommands: MemoryCommandStoreGRDB(writer: pool),
      retriever: RetrieverGRDB(writer: pool),
      scheduledJobs: ScheduledJobStoreGRDB(writer: pool),
      scheduleCommands: ScheduleCommandStoreGRDB(writer: pool),
      approvals: ApprovalStoreGRDB(writer: pool)
    )
  }
}
