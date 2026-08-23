import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import ClawTools
import ClawWorkspace
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

/// One durable audit row, projected to the columns the acceptance clauses assert over.
struct AuditRow: Sendable, Equatable {
  let actor: String
  let action: String
  let tool: String?
  let argsRedacted: String
  let decision: String
}

/// Parses a known-good IP literal for a scripted resolver table. Test fixtures only — a bad literal
/// is a programming error in the test, so it traps rather than force-unwrapping.
func resolvedAddress(_ literal: String) -> ResolvedAddress {
  guard let address = ResolvedAddress.parse(literal) else {
    preconditionFailure("invalid IP literal in test fixture: \(literal)")
  }
  return address
}

/// One end-to-end fixture: Telegram-in (router.handle) to outbox-out, with real stores, real
/// policy, real tools — scripted only at the provider, HTTP, and DNS seams.
struct SC3Harness {
  let router: MessageRouter
  let coordinator: ApprovalCoordinator
  let registry: PendingConfirmationRegistry
  let transport: RecordingTransport

  let stores: ClawStores

  let http: RecordingHTTPExecutor
  let provider: TurnScriptedProvider

  let databasePath: String
  /// One reader over the SAME DB file the stores write — a connection of its own, opened once;
  /// the probes below poll it, and a pool opened per probe made the polling the harness hotspot.
  let readPool: DatabasePool
  let workspaceRoot: URL
  let sessionKey: String

  let waiter: ApprovalWaiter
  let lanes: SessionLaneRegistry

  /// Re-establishes the fabric against the SAME DB after a "restart" (a second harness over one
  /// `databasePath`): cleans terminal-run PENDING rows, re-parks unexpired approvals on their
  /// lanes, sweeps expired ones to DENY, and resumes crash-window APPROVED rows (§6.5/§7).
  func runBootReconciliation() async {
    await ApprovalBootReconciler(
      approvals: stores.approvals,
      runs: stores.runs,
      lanes: lanes,
      coordinator: coordinator,
      waiter: waiter,
      now: { Date() },
      logger: TestLog.silent
    ).reconcile()
  }

  /// Awaits the lane-dispatched turn: polls the outbox until `count` payloads exist (bounded).
  func waitForOutbox(atLeast count: Int) async throws -> [String] {
    let matched = try await pollUntil {
      let payloads = try stores.outbox.pendingOutbound().map(\.payload)
      return payloads.count >= count ? payloads : nil
    }
    return try matched ?? stores.outbox.pendingOutbound().map(\.payload)
  }

  func sessionId() throws -> Int64 {
    try stores.sessionMessages.findSession(sessionKey: sessionKey) ?? 0
  }

  func pending() async throws -> CommandConfirmation? {
    await registry.pending(sessionId: try sessionId())
  }

  func snapshot() throws -> SessionContextSnapshot {
    try stores.sessionMessages.loadContextSnapshot(
      sessionId: try sessionId(),
      throughMessageId: Int64.max,
      limit: 50
    )
  }

  /// Reads the durable audit trail over the harness's own reader on the SAME DB file (the harness
  /// never exposes a raw audit read, so the acceptance clauses inspect `audit_events` directly).
  func auditRows() throws -> [AuditRow] {
    try readPool.read { database in
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
}

/// Per-turn scripted provider: each router-dispatched turn consumes the next SCRIPT (a list of
/// responses for that turn's round-trips). A non-re-proposing script is just a script whose
/// yes-turn entry contains no tool calls.
actor TurnScriptedProvider: LLMProvider {
  typealias BeforeCompletion = @Sendable (Int, ChatRequest) async throws -> Void

  private var scripts: [[ChatResponse]]
  private var currentTurn: [ChatResponse] = []

  private let beforeCompletion: BeforeCompletion?

  private(set) var completions = 0
  private(set) var requests: [ChatRequest] = []

  init(
    scripts: [[ChatResponse]],
    beforeCompletion: BeforeCompletion? = nil
  ) {
    self.scripts = scripts

    self.beforeCompletion = beforeCompletion
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    completions += 1
    requests.append(request)
    try await beforeCompletion?(completions, request)
    if currentTurn.isEmpty, scripts.isEmpty == false {
      currentTurn = scripts.removeFirst()
    }
    guard currentTurn.isEmpty == false else {
      throw ProviderError.terminal(status: nil, message: "unscripted")
    }
    let response = currentTurn.removeFirst()
    if response.toolCalls.isEmpty {
      currentTurn = []  // turn over: the next complete() starts the next script
    }
    return response
  }
}

// swiftlint:disable:next function_body_length
func makeSC3Harness(
  scripts: [[ChatResponse]],
  httpResponses: [String: HTTPResult],
  resolverTable: [String: [ResolvedAddress]] = ["example.com": [resolvedAddress("93.184.216.34")]],
  secretValues: [String] = ["llm-key-abc123"],
  workspaceFiles: [String: String] = [:],
  registry: PendingConfirmationRegistry = PendingConfirmationRegistry(),
  databasePath: String? = nil,
  workspaceRoot: URL? = nil,
  coordinator: ApprovalCoordinator = ApprovalCoordinator(),
  extraTools: [any Tool] = [],
  execEnabled: Bool = false,
  executionBackend: (any ExecutionBackend)? = nil,
  execSettings: ExecuteCodeSettings = ExecuteCodeSettings(
    memoryMiB: 1024,
    cpus: 4,
    timeout: .seconds(30),
    allowEgress: false
  ),
  beforeCompletion: TurnScriptedProvider.BeforeCompletion? = nil,
  dispatcherOverride: (any ToolDispatching)? = nil
) throws -> SC3Harness {
  let fileManager = FileManager.default

  // 1. Temp-file stores. Reuse `databasePath` to model a restart against the SAME DB (spec §17).
  let resolvedDatabasePath =
    databasePath
    ?? fileManager.temporaryDirectory
    .appendingPathComponent("claw-sc3-\(UUID().uuidString).sqlite").path
  let stores = try ClawDatabase.openStores(path: resolvedDatabasePath)
  try stores.allowlist.seedAllowlist(userIds: [7])

  // 2. Temp workspace dir; write `workspaceFiles` (relative path → content) into it. Reuse
  // `workspaceRoot` (with `databasePath`) to model a restart against the SAME disk (spec §17).
  let workspaceRoot =
    workspaceRoot
    ?? fileManager.temporaryDirectory
    .appendingPathComponent("claw-sc3-ws-\(UUID().uuidString)", isDirectory: true)
  try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
  for (relativePath, content) in workspaceFiles {
    let destination = workspaceRoot.appendingPathComponent(relativePath)
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: destination, atomically: true, encoding: .utf8)
  }

  // 3. FileSystemWorkspace behind the real tools and the real ContextBuilder (built at step 5b,
  // once the dispatcher can declare the fence labels the history replay has to reuse).
  let workspace = FileSystemWorkspace(root: workspaceRoot)

  // 4. Real tools over the scripted HTTP + DNS seams and an exact-value redactor.
  let http = RecordingHTTPExecutor(responses: httpResponses)
  let resolver = ScriptedResolver(table: resolverTable)
  let redactor = SecretRedactor(secretValues: secretValues)
  var tools: [any Tool] = [
    FileReadTool(workspaceRoot: workspaceRoot, redactor: redactor),
    FileWriteTool(workspaceRoot: workspaceRoot, redactor: redactor),
    MemoryWriteTool(redactor: redactor),
    SkillLoadTool(
      workspaceRoot: workspaceRoot,
      scanSkills: { workspace.scanSkills() },
      redactor: redactor
    ),
    WebFetchTool(http: http, resolver: resolver, redactor: redactor),
    WebSearchTool(search: ExaSearchProvider(apiKey: "exa-key", http: http)),
  ]
  if let executionBackend {
    tools.append(
      ExecuteCodeTool(
        workspaceRoot: workspaceRoot,
        backend: executionBackend,
        settings: execSettings,
        redactor: redactor
      )
    )
  }
  tools.append(contentsOf: extraTools)

  // 5. GatedToolDispatcher: tier-3 private files load from DISK at gate-evaluation time (rev.1 H1).
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
      enabledDangerousTools: execEnabled ? [ExecuteCodeTool.toolName] : []
    )
  )

  // 5b. ContextBuilder over the real memory/retriever stores, taking the dispatcher's declared
  // fence labels the way composition does — replayed tool rows carry only a tool NAME.
  let contextBuilder = ContextBuilder(
    systemPrompt: SystemPrompt.minimal,
    workspace: workspace,
    memoryStore: stores.memory,
    retriever: stores.retriever,
    budget: .default,
    fenceLabels: ToolFenceLabels(definitions: dispatcher.definitions)
  )

  // 6. AgentRuntime over the per-turn scripted provider and the real gated dispatcher.
  let provider = TurnScriptedProvider(
    scripts: scripts,
    beforeCompletion: beforeCompletion
  )
  let agent = AgentRuntime(
    roster: makeSingleRouteRoster(provider: provider, wireModel: "test-model"),
    typingIndicator: NoopTyping(),
    draftStreamer: NoopRichDraftStreaming(),
    streamingEnabled: false,
    costResolver: CostResolver(
      priceTable: .empty,
      referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
    ),
    budget: .default,
    toolDispatcher: dispatcherOverride ?? dispatcher,
    usageStore: stores.usage,
    auditLog: stores.audit,
    clock: ContinuousClock()
  )

  // 7. TurnRunner sharing the router's registry instance.
  let transport = RecordingTransport()
  let logger = TestLog.silent
  let deferredParker = DeferredApprovalParker()
  let imageCache = ImageCache()
  let runner = TurnRunner(
    sessionMessages: stores.sessionMessages,
    runs: stores.runs,
    usageStore: stores.usage,
    audit: stores.audit,
    agent: agent,
    budget: .default,
    contextBuilder: contextBuilder,
    imageCache: imageCache,
    notifyOutbox: {},
    parker: deferredParker,
    approvalExpirySeconds: testApprovalExpirySeconds,
    logger: logger
  )

  // 7b. The REAL approve-resume fabric (mirrors RunCommand+Composition.makeApprovalFabric):
  // recorded-args executor → waiter adopted into the runner's parker → callback handler the
  // router routes owner taps into.
  let approvedExecutor = ApprovedActionExecutor(
    tools: dispatcher.toolsByName,
    runs: stores.runs,
    redactArguments: { $0 },
    now: { Date() },
    logger: logger
  )
  let waiter = ApprovalWaiter(
    approvals: stores.approvals,
    runs: stores.runs,
    coordinator: coordinator,
    executor: approvedExecutor,
    turns: runner,
    delivery: transport,
    callbacks: transport,
    typing: NoopTyping(),
    clock: ContinuousClock(),
    currentPolicyVersion: { contextBuilder.currentPolicyVersion() },
    now: { Date() },
    logger: logger
  )
  deferredParker.adopt(waiter)
  let approvalCallbacks = ApprovalCallbackHandler.make(
    processed: stores.processed,
    delivery: transport,
    accessControl: AccessControl(allowlist: stores.allowlist),
    approvals: stores.approvals,
    audit: stores.audit,
    coordinator: coordinator,
    callbacks: transport,
    currentPolicyVersion: { contextBuilder.currentPolicyVersion() },
    now: { Date() },
    logger: logger
  )

  // 8. MessageRouter over the real stores + RecordingTransport + SessionLaneRegistry.
  let lanes = SessionLaneRegistry()
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
    imageCache: imageCache,
    lanes: lanes,
    schedule: ScheduleSurface(
      parser: FakeDraftParser(result: .unparseable),
      validator: ScheduleDraftValidator(minIntervalMinutes: 5, defaultTimezone: .gmt),
      calculator: OccurrenceCalculator(),
      jobs: stores.scheduledJobs,
      commands: stores.scheduleCommands
    ),
    approvalCallbacks: approvalCallbacks,
    coordinator: coordinator,
    doctor: StubDoctorReporter(),
    logger: logger
  )

  return SC3Harness(
    router: router,
    coordinator: coordinator,
    registry: registry,
    transport: transport,
    stores: stores,
    http: http,
    provider: provider,
    databasePath: resolvedDatabasePath,
    readPool: try ClawDatabase.makePool(path: resolvedDatabasePath),
    workspaceRoot: workspaceRoot,
    sessionKey: SessionKey.telegramDM(chatId: 7),
    waiter: waiter,
    lanes: lanes
  )
}
