import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V9MigrationTests {
  private static let seededAt = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Legacy Upgrade

  @Test func vNineCarriesEveryPopulatedVEightRowForward() throws {
    // given — a v8 database holding the shapes v9 rebuilds: messages with tool metadata plus
    // run-bound and run-less usage rows
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVEight(queue)

    // when
    try ClawDatabase.migrate(queue)

    // then — every message value survives the rebuild, ids included
    let messages = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM messages ORDER BY id")
    }
    #expect(messages.count == 3)
    #expect(messages[0]["id"] == 1)
    #expect(messages[0]["role"] == "user")
    #expect(messages[0]["content"] == "find the plan")
    #expect(messages[0]["provenance"] == "trusted")
    #expect((messages[0]["run_id"] as Int64?) == nil)
    #expect(messages[1]["id"] == 2)
    #expect(messages[1]["run_id"] == 1)
    #expect(messages[1]["tool_calls"] == #"[{"id":"call-1","name":"file_read"}]"#)
    #expect(messages[1]["prompt_tokens"] == 11)
    #expect(messages[1]["completion_tokens"] == 5)
    #expect(messages[2]["id"] == 3)
    #expect(messages[2]["role"] == "tool")
    #expect(messages[2]["tool_call_id"] == "call-1")
    #expect(messages[2]["provenance"] == "untrusted")

    // and the state pair arrives null on every carried-forward row
    for message in messages {
      #expect((message["provider_state_issuer"] as String?) == nil)
      #expect((message["provider_state"] as Data?) == nil)
    }

    // and every usage value survives, the run-less row's NULL run_id included
    let usage = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM provider_usage ORDER BY id")
    }
    #expect(usage.count == 2)
    #expect(usage[0]["id"] == 1)
    #expect(usage[0]["run_id"] == 1)
    #expect(usage[0]["session_id"] == 1)
    #expect(usage[0]["model"] == "gpt-4o")
    #expect(usage[0]["prompt_tokens"] == 11)
    #expect(usage[0]["completion_tokens"] == 5)
    #expect(usage[0]["cost_usd"] == 0.004)
    #expect(usage[0]["cost_source"] == "price_file")
    #expect(usage[0]["is_estimated"] == false)
    #expect(usage[1]["id"] == 2)
    #expect((usage[1]["run_id"] as Int64?) == nil)
    #expect(usage[1]["model"] == "gpt-4o-mini")
    #expect(usage[1]["cost_source"] == "heuristic")
    #expect(usage[1]["is_estimated"] == true)
  }

  @Test func everyLegacyUsageRowKeepsItsOwnRowIdDerivedCallIdentity() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVEight(queue)

    // when
    try ClawDatabase.migrate(queue)

    // then — the identity is derived from the row id the migration found, so it is reproducible
    let identities = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT id, provider_call_id FROM provider_usage ORDER BY id")
    }
    let pairs = identities.map { row in
      (row["id"] as Int64, row["provider_call_id"] as String)
    }
    #expect(pairs.map(\.1) == ["legacy:1", "legacy:2"])
    #expect(pairs.allSatisfy { identifier in identifier.1 == "legacy:\(identifier.0)" })
    #expect(Set(pairs.map(\.1)).count == pairs.count)
  }

  @Test func vOneDatabaseUpgradesToVNineKeepingItsRowsAndReachingTheFullSchema() throws {
    // given — the oldest shipped schema, holding rows only its three tables can hold
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrator.migrate(queue, upTo: "v1")
    try queue.write { db in
      try db.execute(
        sql: "INSERT INTO allowlist(user_id, added_at) VALUES (7, ?)",
        arguments: [Self.seededAt]
      )
      try db.execute(
        sql: "INSERT INTO processed_updates(update_id, claimed_at) VALUES (42, ?)",
        arguments: [Self.seededAt]
      )
      try db.execute(sql: "INSERT INTO update_cursor(id, last_update_id) VALUES (1, 42)")
    }

    // when
    try ClawDatabase.migrate(queue)

    // then — the pre-existing rows survive every rebuild between v1 and v9
    let owner = try queue.read { db in
      try Int64.fetchOne(db, sql: "SELECT user_id FROM allowlist")
    }
    #expect(owner == 7)
    let claimed = try queue.read { db in
      try Int64.fetchOne(db, sql: "SELECT update_id FROM processed_updates")
    }
    #expect(claimed == 42)
    let cursor = try queue.read { db in
      try Int64.fetchOne(db, sql: "SELECT last_update_id FROM update_cursor")
    }
    #expect(cursor == 42)

    // and the schema the later migrations build is fully present
    let messageColumns = Set(try Self.columnNames(queue, table: "messages"))
    #expect(messageColumns.isSuperset(of: ["provider_state_issuer", "provider_state"]))
    #expect(try Self.columnNames(queue, table: "provider_usage").contains("provider_call_id"))
  }

  // MARK: - Provider State Pair

  @Test func sqliteAcceptsBothStateColumnsNull() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try Self.seedSession(queue)

    // when / then — every row written before v9 has this shape, so it must stay legal
    try queue.write { db in
      try Self.insertMessage(db, issuer: nil, state: nil)
    }
    let stored = try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages")
    }
    #expect(stored == 1)
  }

  @Test func sqliteAcceptsBothStateColumnsPopulated() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try Self.seedSession(queue)

    // when
    try queue.write { db in
      try Self.insertMessage(db, issuer: "openai-chatgpt", state: Data([0x01, 0x02, 0x03]))
    }

    // then
    let stored = try queue.read { db in
      try Row.fetchOne(db, sql: "SELECT provider_state_issuer, provider_state FROM messages")
    }
    #expect(stored?["provider_state_issuer"] == "openai-chatgpt")
    #expect((stored?["provider_state"] as Data?) == Data([0x01, 0x02, 0x03]))
  }

  @Test func sqliteRejectsAnIssuerWithoutState() throws {
    // given — state without the issuer that produced it is unreplayable, and an issuer without
    // state names nothing; the check makes either half unrepresentable
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try Self.seedSession(queue)

    // when / then
    #expect {
      try queue.write { db in
        try Self.insertMessage(db, issuer: "openai-chatgpt", state: nil)
      }
    } throws: { error in
      Self.isCheckViolation(error)
    }
  }

  @Test func sqliteRejectsStateWithoutAnIssuer() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try Self.seedSession(queue)

    // when / then
    #expect {
      try queue.write { db in
        try Self.insertMessage(db, issuer: nil, state: Data([0xFF]))
      }
    } throws: { error in
      Self.isCheckViolation(error)
    }
  }

  @Test func providerStateIsDeclaredAsABlob() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then — opaque bytes, so no affinity coerces a payload the adapter alone may interpret
    #expect(try Self.columnType(queue, table: "messages", column: "provider_state") == "BLOB")
    #expect(
      try Self.columnType(queue, table: "messages", column: "provider_state_issuer") == "TEXT"
    )
  }

  // MARK: - Rebuild Fidelity

  @Test func messagesRetainsEveryColumnAndForeignKeyAfterTheRebuild() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let columns = Set(try Self.columnNames(queue, table: "messages"))
    #expect(
      columns.isSuperset(of: [
        "id", "session_id", "run_id", "role", "content", "provenance", "ts", "prompt_tokens",
        "completion_tokens", "tool_calls", "tool_call_id", "provider_state_issuer",
        "provider_state",
      ])
    )

    let foreignKeys = try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(messages)")
    }
    let described = Set(
      foreignKeys.map { row in
        "\(row["from"] as String)->\(row["table"] as String).\(row["on_delete"] as String)"
      }
    )
    #expect(described == ["session_id->sessions.CASCADE", "run_id->runs.SET NULL"])
  }

  @Test func providerUsageRetainsEveryColumnAndForeignKeyAfterTheRebuild() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let columns = Set(try Self.columnNames(queue, table: "provider_usage"))
    #expect(
      columns.isSuperset(of: [
        "id", "run_id", "session_id", "model", "prompt_tokens", "completion_tokens", "cost_usd",
        "cost_source", "is_estimated", "ts", "provider_call_id",
      ])
    )

    let foreignKeys = try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(provider_usage)")
    }
    let described = Set(
      foreignKeys.map { row in
        "\(row["from"] as String)->\(row["table"] as String).\(row["on_delete"] as String)"
      }
    )
    #expect(described == ["session_id->sessions.CASCADE", "run_id->runs.CASCADE"])

    // and the run stays optional, as v7 established for command-scoped spend
    let runColumn = try #require(
      try queue.read { db in
        try Row.fetchAll(db, sql: "PRAGMA table_info(provider_usage)").first { row in
          row["name"] as String == "run_id"
        }
      }
    )
    #expect(runColumn["notnull"] == 0)
  }

  @Test func theApprovalSchemaSurvivesTheRebuild() throws {
    // given — v8's approvals live alongside the rebuilt tables and must be untouched by v9
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let columns = Set(try Self.columnNames(queue, table: "approvals"))
    #expect(
      columns.isSuperset(of: [
        "id", "run_id", "session_id", "state", "tool", "canonical_args", "canonical_target",
        "args_hash", "policy_version", "owner_user_id", "nonce", "observation_message_id",
        "tool_call_id", "reason", "prompt_message_id", "created_ts", "expires_ts", "resolved_ts",
      ])
    )
    let indexNames = try Self.indexNames(queue, table: "approvals")
    #expect(indexNames.contains("index_approvals_pending_run"))
  }

  @Test func everyPreVNineIndexSurvivesTheRebuild() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    #expect(
      try Self.indexNames(queue, table: "memory_items")
        .isSuperset(of: ["index_memory_items_created_at", "index_memory_items_kind"])
    )
    #expect(
      try Self.indexNames(queue, table: "scheduled_jobs")
        .contains("index_scheduled_jobs_status_next_occurrence")
    )
  }

  // MARK: - FTS Synchronization

  @Test func theRebuiltMessagesTableKeepsItsFtsSynchronizationTriggers() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then — the external-content index is driven by triggers alone; without all three it
    // silently drifts from the table it claims to index
    let triggers = try queue.read { db in
      Set(
        try String.fetchAll(
          db,
          sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'messages'"
        )
      )
    }
    #expect(triggers == ["__messages_fts_ai", "__messages_fts_ad", "__messages_fts_au"])
  }

  @Test func theFtsIndexCarriesNoProviderStateColumn() throws {
    // given — replay state is opaque bytes only its adapter may read; indexing it would both
    // corrupt the index and expose the payload to a content search
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let columns = Set(try Self.columnNames(queue, table: "messages_fts"))
    #expect(columns.contains("content"))
    #expect(columns.contains("provider_state") == false)
    #expect(columns.contains("provider_state_issuer") == false)
  }

  @Test func messagesWrittenBeforeVNineStaySearchableAfterTheRebuild() throws {
    // given — a v8 database whose FTS index was populated by the v4 triggers
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVEight(queue)
    let beforeRebuild = try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'plan'"
      )
    }
    #expect(beforeRebuild == 1)

    // when — v9 drops and recreates both the table and the index over it
    try ClawDatabase.migrate(queue)

    // then — the rebuilt index still points at the same message ids
    let matched = try queue.read { db in
      try Int64.fetchAll(
        db,
        sql: "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'plan OR observation'"
      )
    }
    #expect(Set(matched) == [1, 3])
  }

  @Test func aMessageWrittenAfterTheRebuildIsIndexedAndUnindexedByTheTriggers() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVEight(queue)
    try ClawDatabase.migrate(queue)

    // when
    let messageId = try queue.write { db -> Int64 in
      try Self.insertMessage(db, content: "postmigration needle", issuer: nil, state: nil)
      return db.lastInsertedRowID
    }

    // then — the insert trigger indexed it against its own row id
    let indexed = try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'postmigration'"
      )
    }
    #expect(indexed == messageId)

    // and the delete trigger unindexes it
    try queue.write { db in
      try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [messageId])
    }
    let remaining = try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'postmigration'"
      )
    }
    #expect(remaining == 0)
  }

  // MARK: - Call Identity Constraints

  @Test func aDuplicateCallIdentifierIsRejected() throws {
    // given — the migrated rows already hold their legacy identities
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVEight(queue)
    try ClawDatabase.migrate(queue)

    // when / then — a plain insert reusing an identity violates the unique index
    #expect {
      try queue.write { db in
        try Self.insertUsageSQL(db, callID: "legacy:1")
      }
    } throws: { error in
      Self.isUniqueViolation(error)
    }
  }

  @Test func theCallIdentifierIndexIsUnique() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    let indexSQL = try queue.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT sql FROM sqlite_master
          WHERE type = 'index' AND name = 'index_provider_usage_provider_call_id'
          """
      )
    }
    #expect(indexSQL?.localizedCaseInsensitiveContains("unique") == true)
    #expect(indexSQL?.contains("provider_call_id") == true)
  }

  @Test func theCallIdentifierIsNotNull() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try Self.seedSession(queue)

    // when / then
    #expect {
      try queue.write { db in
        try db.execute(
          sql: """
            INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens,
              completion_tokens, cost_usd, cost_source, is_estimated, ts, provider_call_id)
            VALUES (NULL, 1, 'm', 1, 1, 0.001, 'heuristic', 0, ?, NULL)
            """,
          arguments: [Self.seededAt]
        )
      }
    } throws: { error in
      Self.isNotNullViolation(error)
    }
  }

  // MARK: - Conflict Clause Targeting

  @Test func theInsertStatementSilencesOnlyTheCallIdentityConflict() throws {
    // given — the production statement, replayed with the identity it already stored
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVEight(queue)
    try ClawDatabase.migrate(queue)

    // when
    let changed = try queue.write { db -> Int in
      try db.execute(
        sql: RunStoreGRDB.insertUsageStatement,
        arguments: Self.usageArguments(callID: "legacy:1")
      )
      return db.changesCount
    }

    // then — the replay writes nothing rather than failing
    #expect(changed == 0)
    let rows = try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage")
    }
    #expect(rows == 2)
  }

  @Test func theInsertStatementStillRaisesAnUnrelatedNotNullViolation() throws {
    // given — an untargeted conflict clause would silence this alongside the identity conflict,
    // turning a corrupt row into a no-op the caller reads as an idempotent replay
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVEight(queue)
    try ClawDatabase.migrate(queue)

    // when / then
    #expect {
      try queue.write { db in
        try db.execute(
          sql: RunStoreGRDB.insertUsageStatement,
          arguments: Self.usageArguments(callID: "call-fresh", model: nil)
        )
      }
    } throws: { error in
      Self.isNotNullViolation(error)
    }
  }

  @Test func theInsertStatementStillRaisesAnUnrelatedForeignKeyViolation() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try Self.seedVEight(queue)
    try ClawDatabase.migrate(queue)

    // when / then
    #expect {
      try queue.write { db in
        try db.execute(
          sql: RunStoreGRDB.insertUsageStatement,
          arguments: Self.usageArguments(callID: "call-fresh", runId: 9999)
        )
      }
    } throws: { error in
      Self.isForeignKeyViolation(error)
    }
  }
}

// MARK: - Legacy Fixtures

private extension V9MigrationTests {
  /// A v8 database holding exactly the shapes the v9 rebuild must carry across: a session, a run,
  /// messages with tool metadata, and both a run-bound and a run-less usage row.
  static func seedVEight(_ queue: DatabaseQueue) throws {
    try ClawDatabase.migrator.migrate(queue, upTo: "v8")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:7', ?, ?, 0)
          """,
        arguments: [seededAt, seededAt]
      )
      try db.execute(
        sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (1, 'DONE', ?, ?)",
        arguments: [seededAt, seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts)
          VALUES (1, NULL, 'user', 'find the plan', 'trusted', ?)
          """,
        arguments: [seededAt]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, prompt_tokens,
            completion_tokens, tool_calls)
          VALUES (1, 1, 'assistant', 'reading it now', 'trusted', ?, 11, 5, ?)
          """,
        arguments: [seededAt, #"[{"id":"call-1","name":"file_read"}]"#]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (1, 1, 'tool', 'observation payload', 'untrusted', ?, 'call-1')
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

  static func seedSession(_ queue: DatabaseQueue) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:7', ?, ?, 0)
          """,
        arguments: [seededAt, seededAt]
      )
    }
  }

  static func insertMessage(
    _ db: Database,
    content: String = "state carrier",
    issuer: String?,
    state: Data?
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO messages(session_id, role, content, provenance, ts, provider_state_issuer,
          provider_state)
        VALUES (1, 'assistant', ?, 'trusted', ?, ?, ?)
        """,
      arguments: [content, seededAt, issuer, state]
    )
  }

  /// A plain (conflict-clause free) usage insert, so a uniqueness assertion observes the index
  /// rather than the store's deliberate silencing of it.
  static func insertUsageSQL(_ db: Database, callID: String) throws {
    try db.execute(
      sql: """
        INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
          cost_usd, cost_source, is_estimated, ts, provider_call_id)
        VALUES (NULL, 1, 'm', 1, 1, 0.001, 'heuristic', 0, ?, ?)
        """,
      arguments: [seededAt, callID]
    )
  }

  static func usageArguments(
    callID: String,
    runId: Int64? = 1,
    model: String? = "gpt-4o"
  ) -> StatementArguments {
    [runId, 1, model, 11, 5, 0.004, CostSource.priceFile.rawValue, false, seededAt, callID]
  }
}

// MARK: - Schema Introspection

private extension V9MigrationTests {
  static func columnNames(_ queue: DatabaseQueue, table: String) throws -> [String] {
    try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
        row["name"] as String
      }
    }
  }

  static func columnType(_ queue: DatabaseQueue, table: String, column: String) throws -> String? {
    try queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        .first { row in row["name"] as String == column }
        .map { row in row["type"] as String }
    }
  }

  static func indexNames(_ queue: DatabaseQueue, table: String) throws -> Set<String> {
    try queue.read { db in
      Set(
        try String.fetchAll(
          db,
          sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
          arguments: [table]
        )
      )
    }
  }
}

// MARK: - Constraint Matching

private extension V9MigrationTests {
  static func isCheckViolation(_ error: any Error) -> Bool {
    isConstraintViolation(error, mentioning: "CHECK")
  }

  static func isUniqueViolation(_ error: any Error) -> Bool {
    isConstraintViolation(error, mentioning: "UNIQUE")
  }

  static func isNotNullViolation(_ error: any Error) -> Bool {
    isConstraintViolation(error, mentioning: "NOT NULL")
  }

  static func isForeignKeyViolation(_ error: any Error) -> Bool {
    isConstraintViolation(error, mentioning: "FOREIGN KEY")
  }

  /// Matches the failure mode, not merely "something threw" — a rebuild that lost a constraint
  /// still throws for the wrong reason, and that must not read as a pass.
  static func isConstraintViolation(_ error: any Error, mentioning kind: String) -> Bool {
    guard let databaseError = error as? DatabaseError else {
      return false
    }
    return databaseError.resultCode.primaryResultCode == .SQLITE_CONSTRAINT
      && (databaseError.message?.contains(kind) ?? false)
  }
}
