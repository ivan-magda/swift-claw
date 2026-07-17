import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import ClawTools
import ClawWorkspace
import Foundation
import GRDB
import Testing

@testable import ClawGateway

/// A lock-guarded settable clock: the router, the scheduler, and the assertions all read one
/// injected instant; tests advance it explicitly. No real clocks, no real sleeps.
final class ManualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant: Date

  init(startAt: Date) {
    instant = startAt
  }

  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return instant
  }

  func advance(to next: Date) {
    lock.lock()
    defer { lock.unlock() }
    instant = next
  }
}

/// One end-to-end SC7 fixture: Telegram-in (router.handle) AND scheduler ticks to outbox-out,
/// with real stores, real policy, real tools — scripted only at the provider, HTTP, DNS, and
/// draft-parser seams, plus the settable clock.
struct SC7Harness {
  let router: MessageRouter
  let scheduler: SchedulerService

  let registry: PendingConfirmationRegistry
  let transport: RecordingTransport

  let stores: ClawStores

  let http: RecordingHTTPExecutor
  let provider: TurnScriptedProvider
  let parser: FakeDraftParser

  let clock: ManualClock

  let databasePath: String
  let workspaceRoot: URL

  /// Awaits lane-dispatched turns: polls the outbox until `count` payloads exist (bounded).
  func waitForOutbox(atLeast count: Int) async throws -> [String] {
    let matched = try await pollUntil(timeout: .seconds(5)) {
      let payloads = try stores.outbox.pendingOutbound().map(\.payload)
      return payloads.count >= count ? payloads : nil
    }
    return try matched ?? stores.outbox.pendingOutbound().map(\.payload)
  }

  /// Awaits a lane-dispatched turn that leaves NO outbox row (a suppressed heartbeat): polls the
  /// durable audit trail instead.
  func waitForAudit(action: String, atLeast count: Int) async throws -> Int {
    let matched = try await pollUntil(timeout: .seconds(5)) {
      let matches = try auditRows().filter { row in row.action == action }.count
      return matches >= count ? matches : nil
    }
    return try matched ?? auditRows().filter { row in row.action == action }.count
  }

  func auditRows() throws -> [AuditRow] {
    let pool = try ClawDatabase.makePool(path: databasePath)
    return try pool.read { database in
      try Row.fetchAll(
        database,
        sql: "SELECT actor, action, tool, args_redacted, decision FROM audit_events ORDER BY id"
      ).map { row in
        AuditRow(
          actor: row["actor"],
          action: row["action"],
          tool: row["tool"],
          argsRedacted: row["args_redacted"],
          decision: row["decision"]
        )
      }
    }
  }

  func ownerSessionId() throws -> Int64 {
    try stores.sessionMessages.findSession(sessionKey: SessionKey.telegramDM(chatId: 7)) ?? 0
  }

  func ownerPending() async throws -> PendingConfirmation? {
    await registry.pending(sessionId: try ownerSessionId())
  }

  func jobCount() throws -> Int {
    try stores.scheduledJobs.listAll().count
  }

  func runCount(jobId: Int64) throws -> Int {
    let pool = try ClawDatabase.makePool(path: databasePath)
    return try pool.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM runs WHERE job_id = ?",
        arguments: [jobId]
      ) ?? 0
    }
  }

  func runCount(origin: String) throws -> Int {
    let pool = try ClawDatabase.makePool(path: databasePath)
    return try pool.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM runs WHERE origin = ?",
        arguments: [origin]
      ) ?? 0
    }
  }

  func sessionCount(key: String) throws -> Int {
    let pool = try ClawDatabase.makePool(path: databasePath)
    return try pool.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM sessions WHERE session_key = ?",
        arguments: [key]
      ) ?? 0
    }
  }
}

// swiftlint:disable:next function_body_length
func makeSC7Harness(
  scripts: [[ChatResponse]],
  parseResults: [ScheduleDraftParseResult] = [.unparseable],
  startAt: Date = SchedulingTestClock.mondayNoonBerlin,
  httpResponses: [String: HTTPResult] = [:],
  resolverTable: [String: [ResolvedAddress]] = [
    "example.com": [resolvedAddress("93.184.216.34")],
    "evil.example": [resolvedAddress("93.184.216.35")],
  ],
  secretValues: [String] = ["llm-key-abc123"],
  workspaceFiles: [String: String] = [:],
  heartbeat: HeartbeatSettings = .disabled,
  withBreaker: Bool = false,
  registry: PendingConfirmationRegistry = PendingConfirmationRegistry(),
  databasePath: String? = nil,
  dispatcherOverride: (any ToolDispatching)? = nil
) throws -> SC7Harness {
  let fileManager = FileManager.default
  let clock = ManualClock(startAt: startAt)

  // 1. Temp-file stores. Reuse `databasePath` to model a restart against the SAME DB (spec §17).
  let resolvedDatabasePath =
    databasePath
    ?? fileManager.temporaryDirectory
    .appendingPathComponent("claw-sc7-\(UUID().uuidString).sqlite").path
  let stores = try ClawDatabase.openStores(path: resolvedDatabasePath)
  try stores.allowlist.seedAllowlist(userIds: [7])

  // 2. Temp workspace dir; write `workspaceFiles` (relative path → content) into it.
  let workspaceRoot = fileManager.temporaryDirectory
    .appendingPathComponent("claw-sc7-ws-\(UUID().uuidString)", isDirectory: true)
  try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
  for (relativePath, content) in workspaceFiles {
    let destination = workspaceRoot.appendingPathComponent(relativePath)
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: destination, atomically: true, encoding: .utf8)
  }

  // 3. FileSystemWorkspace + real ContextBuilder over the real memory/retriever stores.
  let workspace = FileSystemWorkspace(root: workspaceRoot)
  let contextBuilder = ContextBuilder(
    systemPrompt: SystemPrompt.minimal,
    workspace: workspace,
    memoryStore: stores.memory,
    retriever: stores.retriever,
    budget: .default
  )

  // 4. Real tools over the scripted HTTP + DNS seams and an exact-value redactor.
  let http = RecordingHTTPExecutor(responses: httpResponses)
  let resolver = ScriptedResolver(table: resolverTable)
  let redactor = SecretRedactor(secretValues: secretValues)
  let tools: [any Tool] = [
    FileReadTool(workspaceRoot: workspaceRoot, redactor: redactor),
    WebFetchTool(http: http, resolver: resolver, redactor: redactor),
    WebSearchTool(search: ExaSearchProvider(apiKey: "exa-key", http: http)),
  ]

  // 5. GatedToolDispatcher: tier-3 private files load from DISK at gate-evaluation time.
  let privateFileLoader: @Sendable () -> [String] = {
    ["MEMORY.md", "USER.md"].compactMap { name in
      try? String(contentsOf: workspaceRoot.appendingPathComponent(name), encoding: .utf8)
    }
  }
  let dispatcher = GatedToolDispatcher(
    registry: ToolRegistry(tools: tools),
    gate: ToolPolicyGate(
      argGuard: ExfilArgGuard(secretValues: secretValues),
      privateFileLoader: privateFileLoader,
      execEnabled: false
    )
  )

  // 6. AgentRuntime over the per-turn scripted provider and the real gated dispatcher.
  let provider = TurnScriptedProvider(scripts: scripts)
  let agent = AgentRuntime(
    provider: provider,
    typingIndicator: NoopTyping(),
    draftStreamer: NoopRichDraftStreaming(),
    streamingEnabled: false,
    costResolver: CostResolver(
      priceTable: .empty,
      referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
    ),
    budget: .default,
    wireModel: "test-model",
    configuredReference: "test-model",
    toolDispatcher: dispatcherOverride ?? dispatcher,
    usageStore: stores.usage,
    auditLog: stores.audit,
    clock: ContinuousClock()
  )

  // 7. TurnRunner sharing the router's registry; the breaker+transport pair only for clause 9.
  //    DEV-2a: the injected clock also drives TurnRunner's proactive "today" window (Task 20b), so
  //    every turn — interactive AND scheduled/heartbeat — reads its budget day from the ManualClock.
  let transport = RecordingTransport()
  let logger = TestLog.silent
  let runner = TurnRunner(
    sessionMessages: stores.sessionMessages,
    runs: stores.runs,
    usageStore: stores.usage,
    audit: stores.audit,
    agent: agent,
    budget: .default,
    contextBuilder: contextBuilder,
    notifyOutbox: {},
    breaker: withBreaker ? BudgetBreaker(budget: .default) : nil,
    delivery: withBreaker ? transport : nil,
    now: { clock.now },
    // Inert on purpose: the SC7 assertions never resolve approvals, so no turn may reach a park.
    parker: InertApprovalParker(coordinator: ApprovalCoordinator()),
    approvalExpirySeconds: testApprovalExpirySeconds,
    logger: logger
  )

  // 8. One lane registry shared by the router AND the scheduler (D1: scheduled fires are
  //    first-class lane citizens beside interactive turns).
  let lanes = SessionLaneRegistry()
  let parser = FakeDraftParser(results: parseResults)
  let router = MessageRouter(
    processed: stores.processed,
    sessionMessages: stores.sessionMessages,
    commands: stores.commands,
    memory: stores.memory,
    memoryCommands: stores.memoryCommands,
    pendingConfirmations: registry,
    botUsername: nil,
    accessControl: AccessControl(allowlist: stores.allowlist),
    delivery: transport,
    turnRunner: runner,
    lanes: lanes,
    schedule: ScheduleSurface(
      parser: parser,
      validator: ScheduleDraftValidator(
        minIntervalMinutes: 5,
        // swiftlint:disable:next force_unwrapping — a fixed, known-valid identifier.
        defaultTimezone: TimeZone(identifier: "Europe/Berlin")!
      ),
      calculator: OccurrenceCalculator(),
      jobs: stores.scheduledJobs,
      commands: stores.scheduleCommands
    ),
    coordinator: ApprovalCoordinator(),
    doctor: StubDoctorReporter(),
    now: { clock.now },
    logger: logger
  )

  // 9. The scheduler under test: manual ticks against the settable clock; sleep never used.
  let scheduler = SchedulerService(
    jobs: stores.scheduledJobs,
    lanes: lanes,
    turns: runner,
    calculator: OccurrenceCalculator(),
    catchUpMaxAge: .seconds(1800),
    heartbeat: heartbeat,
    workspace: workspace,
    audit: stores.audit,
    now: { clock.now },
    clock: ScriptedClock { _ in },
    logger: logger
  )

  return SC7Harness(
    router: router,
    scheduler: scheduler,
    registry: registry,
    transport: transport,
    stores: stores,
    http: http,
    provider: provider,
    parser: parser,
    clock: clock,
    databasePath: resolvedDatabasePath,
    workspaceRoot: workspaceRoot
  )
}
