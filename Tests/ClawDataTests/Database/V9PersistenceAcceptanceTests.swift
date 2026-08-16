import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

/// Closes the persistence phase on one database rather than one seam: a real pre-v9 file is
/// migrated in place, then driven through the suspend, resume, and terminal commit paths with
/// replay state and per-call usage, and read back through the ordinary history seam. The pieces are
/// covered apart elsewhere; what is only observable here is whether they still agree once they run
/// over the same rows.
@Suite struct V9PersistenceAcceptanceTests {
  private static let seededAt = Date(timeIntervalSince1970: 1_700_000_000)
  private static let legacySessionKey = "tg:dm:9"
  /// The run `seedLegacyVEight` writes first, so it takes the first autoincrement id.
  private static let legacyRunId: Int64 = 1

  fileprivate struct Fixture {
    let root: URL
    let pool: DatabasePool
    let sessions: SessionMessageStoreGRDB
    let runs: RunStoreGRDB
    let usage: UsageStoreGRDB
    let sessionId: Int64
    let runId: Int64
  }

  /// The state pair as SQLite actually holds it, so a coerced or half-written pair is visible
  /// rather than papered over by a typed decode that would hide exactly the bug worth catching.
  fileprivate struct StateRow: Equatable {
    let role: String
    let issuer: DatabaseValue
    let payload: DatabaseValue
  }

  /// A v8 database upgraded to v9, with a fresh RUNNING run on the very session the legacy rows
  /// belong to — new work and migrated work share a session, which is what makes their interaction
  /// observable at all.
  private func makeMigratedLegacyRun() throws -> Fixture {
    let root = try makeTemporaryRoot(prefix: "claw-v9-acceptance")
    let pool = try ClawDatabase.makePool(path: root.appendingPathComponent("claw.sqlite").path)
    try Self.seedLegacyVEight(pool)

    try ClawDatabase.migrate(pool)

    let sessions = SessionMessageStoreGRDB(writer: pool)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 10,
        sessionKey: Self.legacySessionKey,
        chatId: 9,
        userId: 9,
        text: "save the plan",
        isEdited: false,
        ts: Self.seededAt
      )
    )
    let runs = RunStoreGRDB(writer: pool)
    let runId = try #require(claim.runId)
    _ = try #require(try runs.pickUp(runId: runId, now: Self.seededAt))

    return Fixture(
      root: root,
      pool: pool,
      sessions: sessions,
      runs: runs,
      usage: UsageStoreGRDB(writer: pool),
      sessionId: try #require(claim.sessionId),
      runId: runId
    )
  }

  /// The whole stateful path a gated turn takes: the mid-loop usage row for the round that made the
  /// proposal, the suspend checkpoint carrying that round's state, the approved resume that fills
  /// the parked observation, and the terminal commit that persists the final anchor with its own
  /// state and its own round's spend. Two logical provider calls, one run.
  @discardableResult
  private func runStatefulTurn(_ env: Fixture) throws -> RunCommitResult {
    try env.usage.recordUsage(Self.toolRoundUsage(env))

    let receipt = try env.runs.commitSuspendedTurn(
      runId: env.runId,
      sessionId: env.sessionId,
      commit: Self.suspendCommit(env),
      now: Self.seededAt
    )
    let claim = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: receipt.observationMessageId,
      notResumableObservationContent: "the run stopped before this could run",
      now: Self.seededAt
    )
    #expect(claim == .committed)

    try env.runs.fillClaimedObservation(
      runId: env.runId,
      observationMessageId: receipt.observationMessageId,
      fill: ClaimedObservationFill(
        content: "wrote the file",
        status: .ok,
        setTainted: false,
        setPrivateData: false,
        audit: ApprovedExecutionAudit(tool: "file_write", argsRedacted: "[REDACTED]"),
        now: Self.seededAt
      )
    )

    return try env.runs.commitAssistantTurn(Self.terminalTurn(env), now: Self.seededAt)
  }

  // MARK: - State Across The Migrated Paths

  @Test func everyAssistantAnchorKeepsItsOwnStateAndNoToolRowReceivesAny() throws {
    // given
    let env = try makeMigratedLegacyRun()
    defer { try? FileManager.default.removeItem(at: env.root) }

    // when
    #expect(try runStatefulTurn(env) == .committed)

    // then — the run's rows oldest first: the parked anchor holding the state its round minted,
    // the observation that round had already collected, the placeholder it pinned, the ungated
    // round's anchor with its own state and the untrusted output it fetched, and the final anchor
    // holding the state the terminal round minted. Each anchor keeps its own, not another's, and
    // no untrusted tool row was given any.
    #expect(
      try Self.stateRows(env) == [
        StateRow(
          role: MessageRole.assistant.rawValue,
          issuer: Self.suspendState.issuer.databaseValue,
          payload: Self.suspendPayload.databaseValue
        ),
        StateRow(role: MessageRole.tool.rawValue, issuer: .null, payload: .null),
        StateRow(role: MessageRole.tool.rawValue, issuer: .null, payload: .null),
        StateRow(
          role: MessageRole.assistant.rawValue,
          issuer: Self.exchangeState.issuer.databaseValue,
          payload: Self.exchangePayload.databaseValue
        ),
        StateRow(role: MessageRole.tool.rawValue, issuer: .null, payload: .null),
        StateRow(
          role: MessageRole.assistant.rawValue,
          issuer: Self.terminalState.issuer.databaseValue,
          payload: Self.terminalPayload.databaseValue
        ),
      ]
    )
  }

  @Test func ordinaryHistoryAndSearchAreUnchangedByTheStatePair() throws {
    // given — a session holding both eras: rows the migration carried across and rows written
    // through the v9 stores
    let env = try makeMigratedLegacyRun()
    defer { try? FileManager.default.removeItem(at: env.root) }
    try runStatefulTurn(env)

    // when — the ordinary read seam, asked for nothing about state
    let history = try env.sessions.loadContextSnapshot(
      sessionId: env.sessionId,
      throughMessageId: Int64.max,
      limit: 50
    ).history

    // then — the window reads exactly as a pre-v9 window did, state riding along on the anchors
    #expect(
      history.map(\.role) == [
        .assistant, .user, .assistant, .tool, .tool, .assistant, .tool,
        .assistant,
      ]
    )
    #expect(history.map(\.content).first == "the archived plan")
    #expect(
      history.map(\.providerState) == [
        nil, nil, Self.suspendState, nil, nil, Self.exchangeState, nil, Self.terminalState,
      ]
    )

    // and no payload reached the text a renderer would carry
    let rendered = history.map(\.content).joined(separator: "\n")
    #expect(rendered.contains(Self.suspendPayloadAsLossyText) == false)
    #expect(rendered.contains(Self.exchangePayloadAsLossyText) == false)
    #expect(rendered.contains(Self.terminalPayloadAsLossyText) == false)

    // and the rebuilt index still spans the migration boundary, matching on text alone
    #expect(try Self.search(env, "plan") == [1, 2])
    #expect(try Self.search(env, "confirmed") == [8])
  }

  // MARK: - Usage Across The Migrated Paths

  @Test func twoLogicalCallsRecomputeTheTotalsAndLeaveLegacyIdentitiesAlone() throws {
    // given
    let env = try makeMigratedLegacyRun()
    defer { try? FileManager.default.removeItem(at: env.root) }

    // when — the full turn, then the terminal commit re-presented against the finished run
    #expect(try runStatefulTurn(env) == .committed)
    let replay = try env.runs.commitAssistantTurn(Self.terminalTurn(env), now: Self.seededAt)

    // then — the run owns one usage row per logical round, and the replay added neither a third of
    // those nor a repeat of any anchor: the parked one, the ungated round's, and the final one
    #expect(replay == .ignored)
    #expect(
      try Self.callIdentities(env, runId: env.runId) == [Self.toolCallID, Self.terminalCallID]
    )
    #expect(try Self.assistantRowCount(env) == 3)

    // and the totals are the sum over both rows: the terminal round's late row did not erase the
    // tool round that preceded it
    let totals = try Self.runTotals(env)
    #expect(totals.inputTokens == 150)
    #expect(totals.outputTokens == 30)
    #expect(totals.costUSD == 0.04)

    // and the rows the migration derived identities for are untouched by any of it
    #expect(try Self.callIdentities(env, runId: Self.legacyRunId) == ["legacy:1"])
    #expect(try Self.usageCount(env) == 4)
  }

  @Test func aTerminalCommitAfterCancellationRecordsItsCallOnceAcrossReplays() throws {
    // given — a run whose tool round already spent, cancelled out from under the turn in flight
    let env = try makeMigratedLegacyRun()
    defer { try? FileManager.default.removeItem(at: env.root) }
    try env.usage.recordUsage(Self.toolRoundUsage(env))
    #expect(
      try env.runs.cancelActiveRun(
        sessionId: env.sessionId,
        reason: .cancelled,
        now: Self.seededAt
      ) == env.runId
    )

    // when — the terminal commit lands late, then is replayed
    let first = try env.runs.commitAssistantTurn(Self.terminalTurn(env), now: Self.seededAt)
    let second = try env.runs.commitAssistantTurn(Self.terminalTurn(env), now: Self.seededAt)

    // then — the late spend is recorded once; the replay meets its own identity and writes nothing
    #expect(first == .usageRecordedAfterTerminal)
    #expect(second == .ignored)
    #expect(
      try Self.callIdentities(env, runId: env.runId) == [Self.toolCallID, Self.terminalCallID]
    )

    // and the totals still count the tool round the late row arrived after — a run-wide "has usage
    // yet?" guard would have dropped the terminal spend here, and a replay that debited again
    // would have doubled it
    let totals = try Self.runTotals(env)
    #expect(totals.inputTokens == 150)
    #expect(totals.outputTokens == 30)
    #expect(totals.costUSD == 0.04)
  }

  // MARK: - Conflict Targeting At The Store Seam

  @Test func aReplayedCallIdentityIsSilencedAtTheTypedSeamAndKeepsTheStoredRow() throws {
    // given
    let env = try makeMigratedLegacyRun()
    defer { try? FileManager.default.removeItem(at: env.root) }
    try env.usage.recordUsage(Self.toolRoundUsage(env))

    // when — the same identity re-presented carrying different figures
    try env.usage.recordUsage(
      makeProviderUsage(
        runId: env.runId,
        sessionId: env.sessionId,
        callID: Self.toolCallID,
        promptTokens: 999,
        completionTokens: 999
      )
    )

    // then — no failure reaches the caller, one row stands, and it is the first attempt's: the
    // conflict resolves by doing nothing, not by overwriting what was already accounted for
    let stored = try Self.runUsageFigures(env)
    #expect(stored.count == 1)
    #expect(stored.first?.promptTokens == 100)
    #expect(stored.first?.completionTokens == 20)
  }

  @Test func anUnrelatedNotNullFailureCrossesTheSeamAsATypedStoreError() throws {
    // given — a NULL is unreachable through `ProviderUsage`, whose fields are non-optional, so the
    // production statement is driven straight at the mapping seam every store write already uses.
    // An untargeted conflict clause would swallow this failure and hand the caller the same
    // "wrote nothing" a harmless replay produces.
    let env = try makeMigratedLegacyRun()
    defer { try? FileManager.default.removeItem(at: env.root) }

    // when / then
    #expect {
      try MappedDatabase(writer: env.pool).writeMapping { db in
        try db.execute(
          sql: RunStoreGRDB.insertUsageStatement,
          arguments: Self.usageArguments(env, callID: "call-fresh", model: nil)
        )
      }
    } throws: { error in
      Self.isTypedFailure(error, mentioning: "NOT NULL constraint failed: provider_usage.model")
    }
    #expect(try Self.usageCount(env) == 2)
  }

  @Test func aMismatchedStatePairCrossesTheSeamAsATypedStoreError() throws {
    // given — likewise unreachable through `MessageRowInsert`, which binds both halves or neither;
    // a foreign writer is what the pair CHECK is there to stop
    let env = try makeMigratedLegacyRun()
    defer { try? FileManager.default.removeItem(at: env.root) }

    // when / then
    #expect {
      try MappedDatabase(writer: env.pool).writeMapping { db in
        try db.execute(
          sql: """
            INSERT INTO messages(session_id, role, content, provenance, ts,
              provider_state_issuer, provider_state)
            VALUES (?, 'assistant', 'half a pair', 'trusted', ?, 'openai-chatgpt', NULL)
            """,
          arguments: [env.sessionId, Self.seededAt]
        )
      }
    } throws: { error in
      Self.isTypedFailure(error, mentioning: "CHECK constraint failed")
    }
  }

  @Test func anUnrelatedForeignKeyFailureCrossesTheSeamAsATypedStoreError() throws {
    // given — this one the typed store can express, so it is driven through the real constructor
    let env = try makeMigratedLegacyRun()
    defer { try? FileManager.default.removeItem(at: env.root) }

    // when / then
    #expect {
      try env.usage.recordUsage(
        makeProviderUsage(runId: 9999, sessionId: env.sessionId, callID: "call-orphan")
      )
    } throws: { error in
      Self.isTypedFailure(error, mentioning: "FOREIGN KEY constraint failed")
    }
    #expect(try Self.usageCount(env) == 2)
  }
}

// MARK: - Replay State Fixtures

extension V9PersistenceAcceptanceTests {
  /// Deliberately not valid UTF-8, so a seam that stringified the blob would mangle it rather than
  /// round-trip it, and distinct per anchor so a path that mixed them up cannot read as a pass.
  static let suspendPayload = Data([0x00, 0xC3, 0x28, 0xFF])
  static let exchangePayload = Data([0x03, 0xF5, 0xBE, 0x81])
  static let terminalPayload = Data([0x80, 0xFE, 0x01, 0x02])

  // The lossy conversion is the point here: the failable initializer the rule prefers returns nil
  // for these bytes, which would assert nothing at all.
  // swiftlint:disable optional_data_string_conversion

  /// The payloads as a leak would actually expose them. Searching rendered text for the raw bytes
  /// can never fail — a `String`'s UTF-8 view cannot emit `0xFF`/`0xFE` — so non-exposure is
  /// asserted against the lossy form a stringifying seam really produces.
  static let suspendPayloadAsLossyText = String(decoding: suspendPayload, as: UTF8.self)
  static let exchangePayloadAsLossyText = String(decoding: exchangePayload, as: UTF8.self)
  static let terminalPayloadAsLossyText = String(decoding: terminalPayload, as: UTF8.self)

  // swiftlint:enable optional_data_string_conversion

  static let suspendState = ProviderExchangeState(
    issuer: "openai-chatgpt-responses-v1:suspend",
    payload: suspendPayload
  )
  static let exchangeState = ProviderExchangeState(
    issuer: "openai-chatgpt-responses-v1:exchange",
    payload: exchangePayload
  )
  static let terminalState = ProviderExchangeState(
    issuer: "openai-chatgpt-responses-v1:terminal",
    payload: terminalPayload
  )
}

// MARK: - Turn Fixtures

private extension V9PersistenceAcceptanceTests {
  static let toolCallID = "call-tool-round"
  static let terminalCallID = "call-terminal-round"

  static func toolRoundUsage(_ env: Fixture) -> ProviderUsage {
    makeProviderUsage(
      runId: env.runId,
      sessionId: env.sessionId,
      callID: toolCallID,
      promptTokens: 100,
      completionTokens: 20,
      costUSD: 0.03,
      costSource: .priceFile,
      ts: seededAt
    )
  }

  static func terminalRoundUsage(_ env: Fixture) -> ProviderUsage {
    makeProviderUsage(
      runId: env.runId,
      sessionId: env.sessionId,
      callID: terminalCallID,
      promptTokens: 50,
      completionTokens: 10,
      costUSD: 0.01,
      costSource: .priceFile,
      ts: seededAt
    )
  }

  static func suspendCommit(_ env: Fixture) -> SuspendedTurnCommit {
    SuspendedTurnCommit(
      assistantContent: "Let me save that.",
      toolCallsJSON: #"[{"id":"w1","name":"file_write","arguments":"{}"}]"#,
      completedObservations: [ToolObservationRow(toolCallId: "w0", content: "already ran")],
      pending: PendingToolAction(
        toolCallId: "w1",
        recorded: RecordedToolAction(
          tool: "file_write",
          canonicalArgsJSON: #"{"content":"hi","path":"notes/plan.md"}"#,
          argsHash: "hash16",
          canonicalTarget: "/workspace/notes/plan.md",
          reason: .askTier,
          presentation: ToolApprovalPresentation(
            blastRadius: "create, 2 B",
            contentPreview: "hi",
            warnings: []
          )
        )
      ),
      ownerUserId: 9,
      nonce: "n0",
      promptChunks: [
        OutboxChunk(
          stepIndex: 0,
          chatId: 9,
          payload: "Approve writing /workspace/notes/plan.md?",
          payloadHash: "hash",
          approvalId: nil,
          replyMarkup: #"{"inline_keyboard":[[{"text":"Approve","callback_data":"apr:n0:y"}]]}"#
        )
      ],
      setTainted: false,
      setPrivateData: false,
      providerState: suspendState,
      expiresTs: seededAt.addingTimeInterval(3600)
    )
  }

  /// A round the turn executed without gating, carrying the state its proposal was minted with —
  /// the one path onto migrated rows that the suspend/resume fixtures never reach.
  static let statefulExchange = ToolExchange(
    assistantContent: "let me check the log",
    toolCalls: [
      ToolCall(id: "r1", name: "file_read", argumentsJSON: #"{"path":"notes/log.md"}"#)
    ],
    observations: [
      ToolObservation(
        callId: "r1",
        toolName: "file_read",
        content: "raw log text",
        status: .ok,
        ingestedUntrusted: true
      )
    ],
    providerState: exchangeState
  )

  static func terminalTurn(_ env: Fixture) -> AssistantTurn {
    AssistantTurn(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 9,
      content: "saved and confirmed",
      usage: terminalRoundUsage(env),
      chunks: [
        OutboxChunk(stepIndex: 0, chatId: 9, payload: "saved and confirmed", payloadHash: "hash2")
      ],
      exchanges: [statefulExchange],
      providerState: terminalState
    )
  }

  static func usageArguments(
    _ env: Fixture,
    callID: String,
    model: String?
  ) -> StatementArguments {
    [
      env.runId, env.sessionId, model, 11, 5, 0.004, CostSource.priceFile.rawValue, false,
      seededAt, callID,
    ]
  }
}

// MARK: - Legacy Fixture

private extension V9PersistenceAcceptanceTests {
  /// A pre-v9 database holding what this suite needs to observe surviving: a session later runs
  /// keep using, and usage rows the migration must give derived identities. Fidelity of the
  /// rebuild itself is `V9MigrationTests`' subject, not this one's.
  static func seedLegacyVEight(_ pool: DatabasePool) throws {
    try ClawDatabase.migrator.migrate(pool, upTo: "v8")
    try pool.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES (?, ?, ?, 0)
          """,
        arguments: [legacySessionKey, seededAt, seededAt]
      )
      try db.execute(
        sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (1, 'DONE', ?, ?)",
        arguments: [seededAt, seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts)
          VALUES (1, 1, 'assistant', 'the archived plan', 'trusted', ?)
          """,
        arguments: [seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
            cost_usd, cost_source, is_estimated, ts)
          VALUES (1, 1, 'gpt-4o', 11, 5, 0.004, 'price_file', 0, ?)
          """,
        arguments: [seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
            cost_usd, cost_source, is_estimated, ts)
          VALUES (NULL, 1, 'gpt-4o-mini', 7, 2, 0.001, 'heuristic', 1, ?)
          """,
        arguments: [seededAt]
      )
    }
  }
}

// MARK: - Readback

private extension V9PersistenceAcceptanceTests {
  struct RunTotals: Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
  }

  struct UsageFigures: Equatable {
    let promptTokens: Int
    let completionTokens: Int
  }

  static func stateRows(_ env: Fixture) throws -> [StateRow] {
    try env.pool.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT role, \(ProviderStateCoding.selection) FROM messages
          WHERE run_id = ? ORDER BY id ASC
          """,
        arguments: [env.runId]
      )
      .map { row in
        StateRow(
          role: row["role"],
          issuer: row[ProviderStateCoding.issuerColumn],
          payload: row[ProviderStateCoding.payloadColumn]
        )
      }
    }
  }

  static func callIdentities(_ env: Fixture, runId: Int64) throws -> [String] {
    try env.pool.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT provider_call_id FROM provider_usage WHERE run_id = ? ORDER BY id ASC",
        arguments: [runId]
      )
    }
  }

  static func usageCount(_ env: Fixture) throws -> Int {
    try env.pool.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage") ?? 0
    }
  }

  static func assistantRowCount(_ env: Fixture) throws -> Int {
    try env.pool.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND role = ?",
        arguments: [env.runId, MessageRole.assistant.rawValue]
      ) ?? 0
    }
  }

  static func runUsageFigures(_ env: Fixture) throws -> [UsageFigures] {
    try env.pool.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT prompt_tokens, completion_tokens FROM provider_usage
          WHERE run_id = ? ORDER BY id ASC
          """,
        arguments: [env.runId]
      )
      .map { row in
        UsageFigures(promptTokens: row["prompt_tokens"], completionTokens: row["completion_tokens"])
      }
    }
  }

  static func runTotals(_ env: Fixture) throws -> RunTotals {
    try env.pool.read { db in
      let row = try Row.fetchOne(
        db,
        sql: "SELECT input_tokens, output_tokens, cost_usd FROM runs WHERE id = ?",
        arguments: [env.runId]
      )
      guard let row else {
        throw StoreError.unexpected("run \(env.runId) vanished")
      }
      return RunTotals(
        inputTokens: row["input_tokens"],
        outputTokens: row["output_tokens"],
        costUSD: row["cost_usd"]
      )
    }
  }

  static func search(_ env: Fixture, _ term: String) throws -> [Int64] {
    try env.pool.read { db in
      try Int64.fetchAll(
        db,
        sql: "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rowid ASC",
        arguments: [term]
      )
    }
  }

  /// Matches the failure mode, not merely "a `StoreError` arrived": a seam that collapsed every
  /// failure into one opaque case would still throw, and that must not read as a pass.
  static func isTypedFailure(_ error: any Error, mentioning kind: String) -> Bool {
    guard
      let storeError = error as? StoreError,
      case .unexpected(let message) = storeError
    else {
      return false
    }
    return message.contains(kind)
  }
}
