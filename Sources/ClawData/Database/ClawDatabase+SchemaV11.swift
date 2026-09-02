import ClawCore
import Foundation
import GRDB

// MARK: - Learning State

extension ClawDatabase {
  /// The job's own learning row and the immutable lesson sets it points at. Lesson-set identity is
  /// the pair `(job_id, digest)`: the digest covers content alone, so the canonical empty set
  /// collides across jobs the moment a second job arms.
  static func createLearningStateTables(_ db: Database) throws {
    try db.create(table: "job_learning_state") { table in
      table.column("job_id", .integer).primaryKey()
        .references("scheduled_jobs", onDelete: .cascade)
      table.column("learning_epoch", .integer).notNull().defaults(to: 1)
      table.column("stable_lesson_set_digest", .text).notNull()
      table.column("stable_revision", .integer).notNull().defaults(to: 0)
      table.column("open_trial_id", .integer)
      table.column("feedback_revision", .integer).notNull().defaults(to: 0)
      table.column("armed_at", .integer).notNull()
    }

    try db.create(table: "lesson_sets") { table in
      table.column("job_id", .integer).notNull()
      table.column("digest", .text).notNull()
      table.column("schema_version", .integer).notNull()
      table.column("canonical_bytes", .blob).notNull()
      table.column("source", .text).notNull()
      table.column("created_at", .integer).notNull()
      table.primaryKey(["job_id", "digest"])
    }
  }
}

// MARK: - Run-Scoped Learning Facts

extension ClawDatabase {
  /// What one created run froze about its own learning context, and what its terminal transition
  /// settled. Every column here is written while the value is still current: a compatibility field
  /// read back at sealing time would file the run under a surface it never ran on.
  static func createLearningRunTables(_ db: Database) throws {
    try db.create(table: "run_learning_bindings") { table in
      table.column("run_id", .integer).primaryKey()
        .references("runs", onDelete: .cascade)
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("occurrence_at", .integer).notNull()
      table.column("fire_kind", .text).notNull()
      table.column("job_definition_digest", .text).notNull()
      table.column("stable_digest", .text).notNull()
      table.column("effective_digest", .text).notNull()
      table.column("trial_id", .integer)
      table.column("trial_generation", .integer)
      table.foreignKey(["job_id", "effective_digest"], references: "lesson_sets")
    }
    try db.create(index: "idx_bindings_job", on: "run_learning_bindings", columns: ["job_id"])

    try db.create(table: "run_compatibility") { table in
      table.column("run_id", .integer).primaryKey()
        .references("runs", onDelete: .cascade)
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("context_schema_version", .text)
      table.column("tool_catalog_digest", .text)
      table.column("policy_version", .text)
      table.column("skill_set_digest", .text)
      table.column("configured_route", .text)
      table.column("evaluator_route", .text)
      table.column("evidence_schema_version", .text)
      table.column("classifier_version", .text)
      table.column("evaluator_prompt_version", .text)
      table.column("evaluator_schema_version", .text)
      table.column("rubric_version", .text)
    }

    try createSettlementTables(db)
  }

  /// The terminal receipt and the settlement marker share one row: `settled_at` is the correctness
  /// boundary every primary-fact writer refuses to write past. It reaches its job through
  /// `run_learning_bindings` because `RunStore` writes it on the primary run path, which holds no
  /// learning state of its own.
  private static func createSettlementTables(_ db: Database) throws {
    try db.create(table: "run_settlements") { table in
      table.column("run_id", .integer).primaryKey()
        .references("runs", onDelete: .cascade)
      table.column("winning_state", .text).notNull()
      table.column("terminal_cause", .text).notNull()
      table.column("terminal_at", .integer).notNull()
      table.column("settled_at", .integer)
      table.column("configured_route", .text)
      table.column("terminal_route", .text)
    }
    try db.create(
      index: "idx_settlements_settled",
      on: "run_settlements",
      columns: ["settled_at"]
    )

    try db.create(table: "learning_evidence") { table in
      table.column("run_id", .integer).primaryKey()
        .references("runs", onDelete: .cascade)
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("evidence_digest", .text).notNull()
      // Nulled by the 30-day payload sweep; the compact receipt around it lives 90 days.
      table.column("payload", .blob)
      table.column("exclusion_reason", .text)
      table.column("eligibility", .text).notNull()
      table.column("classifier_version", .text).notNull()
      table.column("sealed_at", .integer).notNull()
    }
    try db.create(
      index: "idx_evidence_job_epoch_sealed",
      on: "learning_evidence",
      columns: ["job_id", "learning_epoch", "sealed_at"]
    )
  }
}

// MARK: - Learning Model Calls

extension ClawDatabase {
  /// One durable row per learning model call, plus the frozen verdict a completed evaluator call
  /// produced. Both carry `job_id` and `learning_epoch` as stored columns: a reflector operation's
  /// `source_digest` names a trigger rather than one evidence row, so there is no reliable join
  /// back to the job.
  static func createLearningOperationTables(_ db: Database) throws {
    try db.create(table: "learning_operations") { table in
      table.column("operation_id", .text).primaryKey()
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("phase", .text).notNull()
      table.column("source_digest", .text).notNull()
      table.column("carrier_digest", .text)
      table.column("route", .text)
      table.column("provider_call_id", .text)
      table.column("attempt_generation", .integer).notNull().defaults(to: 0)
      table.column("supersedes", .text).references("learning_operations")
      table.column("state", .text).notNull()
      table.column("failure_code", .text)
      table.column("reserved_tokens", .integer)
      table.column("reserved_cost_usd", .double)
      table.column("reservation_state", .text)
      table.column("created_at", .integer).notNull()
    }
    try db.create(
      index: "idx_learning_operations_job_epoch_phase",
      on: "learning_operations",
      columns: ["job_id", "learning_epoch", "phase"]
    )

    try db.create(table: "learning_evaluations") { table in
      table.column("evaluation_digest", .text).primaryKey()
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("run_id", .integer).notNull().references("runs", onDelete: .cascade)
      table.column("evidence_digest", .text).notNull()
      table.column("outcome", .text).notNull()
      table.column("issue_codes", .text).notNull()
      table.column("rubric_version", .text).notNull()
      table.column("evaluator_prompt_version", .text).notNull()
      table.column("evaluator_schema_version", .text).notNull()
      table.column("compatibility_digest", .text).notNull()
      table.column("created_at", .integer).notNull()
    }
    try db.create(
      index: "idx_learning_evaluations_job_epoch",
      on: "learning_evaluations",
      columns: ["job_id", "learning_epoch"]
    )
  }
}

// MARK: - Owner Feedback

extension ClawDatabase {
  /// The addressable subjects an owner may act on, the live challenge that disambiguates a bare
  /// reply, and the append-only log of what the owner actually said.
  static func createLearningFeedbackTables(_ db: Database) throws {
    try db.create(table: "feedback_targets") { table in
      table.autoIncrementedPrimaryKey("target_id")
      table.column("nonce", .text).notNull()
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("subject_kind", .text).notNull()
      table.column("subject_digest", .text).notNull()
      table.column("allowed_actions", .text).notNull()
      table.column("owner_user_id", .integer).notNull()
      table.column("chat_id", .integer).notNull()
      table.column("expires_at", .integer).notNull()
      table.column("consumed_at", .integer)
    }
    // Lookup is by nonce alone, never by row id: the nonce is the only value the owner's transport
    // hands back, and it has to resolve to exactly one target.
    try db.create(
      index: "idx_feedback_targets_nonce",
      on: "feedback_targets",
      columns: ["nonce"],
      options: [.unique]
    )

    try createFeedbackChallengeTables(db)
  }

  private static func createFeedbackChallengeTables(_ db: Database) throws {
    try db.create(table: "feedback_challenges") { table in
      table.autoIncrementedPrimaryKey("challenge_id")
      table.column("owner_user_id", .integer).notNull()
      table.column("chat_id", .integer).notNull()
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("subject_kind", .text).notNull()
      table.column("subject_digest", .text).notNull()
      table.column("superseded_by", .integer).references("feedback_challenges")
      table.column("consumed_at", .integer)
      table.column("expires_at", .integer).notNull()
    }
    // One owner DM holds at most one live challenge, so a bare "yes" is never ambiguous.
    try db.create(
      index: "idx_feedback_challenges_live",
      on: "feedback_challenges",
      columns: ["owner_user_id", "chat_id"],
      options: [.unique],
      condition: Column("superseded_by") == nil && Column("consumed_at") == nil
    )

    try db.create(table: "feedback_events") { table in
      table.autoIncrementedPrimaryKey("event_id")
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("subject_kind", .text).notNull()
      table.column("subject_digest", .text).notNull()
      table.column("signal", .text).notNull()
      table.column("payload", .text)
      table.column("actor", .text).notNull()
      table.column("transport_update_id", .integer)
      table.column("feedback_revision", .integer).notNull()
      table.column("supersedes", .integer).references("feedback_events")
      table.column("occurred_at", .integer).notNull()
    }
    try db.create(
      index: "idx_feedback_events_job_epoch_revision",
      on: "feedback_events",
      columns: ["job_id", "learning_epoch", "feedback_revision"]
    )
  }
}

// MARK: - Candidates, Trials and Decisions

extension ClawDatabase {
  /// The immutable proposal a reflector froze, and the trial that exposes it. Both carry the
  /// algorithm identity, so a later algorithm version never silently reinterprets frozen work.
  static func createLearningCandidateTables(_ db: Database) throws {
    try db.create(table: "learning_candidates") { table in
      table.column("candidate_digest", .text).primaryKey()
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("replacement_digest", .text).notNull()
      table.column("base_digest", .text).notNull()
      table.column("base_revision", .integer).notNull()
      table.column("frozen_feedback_revision", .integer).notNull()
      table.column("origin", .text).notNull()
      table.column("source_manifest", .text).notNull()
      table.column("predecessor_digest", .text)
      table.column("algorithm", .text).notNull()
      table.column("created_at", .integer).notNull()
      table.foreignKey(["job_id", "replacement_digest"], references: "lesson_sets")
    }
    try db.create(
      index: "idx_learning_candidates_job_epoch",
      on: "learning_candidates",
      columns: ["job_id", "learning_epoch"]
    )

    try db.create(table: "learning_trials") { table in
      table.autoIncrementedPrimaryKey("trial_id")
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("base_digest", .text).notNull()
      table.column("candidate_digest", .text).notNull().references("learning_candidates")
      table.column("generation", .integer).notNull()
      table.column("admitted_at", .integer).notNull()
      table.column("assignment_deadline", .integer).notNull()
      table.column("decision_deadline", .integer).notNull()
      table.column("max_assignments", .integer).notNull()
      table.column("consumed_assignments", .integer).notNull().defaults(to: 0)
      table.column("cohort_cutoff", .integer).notNull()
      table.column("state", .text).notNull()
      table.column("close_reason", .text)
      table.column("algorithm", .text).notNull()
    }
    // One job holds at most one open trial, so two candidates can never contend for the same runs.
    try db.create(
      index: "idx_learning_trials_open_job",
      on: "learning_trials",
      columns: ["job_id"],
      options: [.unique],
      condition: Column("state") == LearningTrialState.open.rawValue
    )
  }

  /// One assignment per created trial run, and the decision receipts the trial policy emits.
  static func createLearningTrialResolutionTables(_ db: Database) throws {
    try db.create(table: "trial_assignments") { table in
      table.column("run_id", .integer).primaryKey()
        .references("runs", onDelete: .cascade)
      table.column("trial_id", .integer).notNull().references("learning_trials")
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("trial_generation", .integer).notNull()
      table.column("assigned_at", .integer).notNull()
      table.column("state", .text).notNull()
      // A resolution *at a revision*, never a frozen verdict: a later owner signal re-resolves the
      // same assignment, and the revision it was resolved under is what makes that detectable.
      table.column("outcome", .text)
      table.column("issue_codes", .text)
      table.column("evaluation_digest", .text)
      table.column("evaluation_required", .boolean).notNull()
      table.column("effective_feedback_revision", .integer)
      table.column("resolved_at", .integer)
    }
    try db.create(
      index: "idx_trial_assignments_trial",
      on: "trial_assignments",
      columns: ["trial_id"]
    )

    try db.create(table: "learning_decisions") { table in
      table.autoIncrementedPrimaryKey("decision_id")
      table.column("kind", .text).notNull()
      table.column("job_id", .integer).notNull()
      table.column("learning_epoch", .integer).notNull()
      table.column("inputs", .text).notNull()
      table.column("result", .text).notNull()
      table.column("algorithm", .text).notNull()
      table.column("decided_at", .integer).notNull()
    }
    try db.create(
      index: "idx_learning_decisions_job_epoch_decided",
      on: "learning_decisions",
      columns: ["job_id", "learning_epoch", "decided_at"]
    )
  }
}

// MARK: - Learning Spend Scope

extension ClawDatabase {
  /// Scopes a usage row to the learning operation that spent it. Both columns stay nullable: an
  /// ordinary turn's usage belongs to no operation, and the learning budget must never see it.
  static func addLearningUsageScope(_ db: Database) throws {
    try db.alter(table: "provider_usage") { table in
      table.add(column: "learning_operation_id", .text)
      table.add(column: "learning_job_id", .integer)
    }
    try db.create(
      index: "idx_provider_usage_learning_operation",
      on: "provider_usage",
      columns: ["learning_operation_id"]
    )
    try db.create(
      index: "idx_provider_usage_learning_job",
      on: "provider_usage",
      columns: ["learning_job_id"]
    )
  }
}

// MARK: - Outbound Delivery Rebuild

extension ClawDatabase {
  /// Relaxes `outbound_deliveries.run_id` to nullable so a delivery that belongs to no run — a
  /// learning notice — can be enqueued at all. SQLite cannot drop a `NOT NULL` in place, so the
  /// table is rebuilt the way v9 rebuilt `messages` and `provider_usage`. The row's identity moves
  /// to the `dedup_key` the table has always carried; the run stays as provenance, and the CHECK
  /// keeps a row that still claims run provenance from losing its run.
  static func rebuildOutboundDeliveriesWithoutRunOwnership(_ db: Database) throws {
    try db.create(table: "outbound_deliveries_new") { table in
      table.column("run_id", .integer).references("runs", onDelete: .cascade)
      table.column("step_index", .integer).notNull()
      table.column("chat_id", .integer).notNull()
      table.column("dedup_key", .text).notNull().unique()
      table.column("payload", .text).notNull()
      table.column("payload_hash", .text).notNull()
      table.column("telegram_message_id", .integer)
      table.column("status", .text).notNull()
      table.column("created_ts", .datetime).notNull()
      table.column("sent_ts", .datetime)
      table.column("approval_id", .integer).references("approvals")
      table.column("reply_markup", .text)
      table.column("message_thread_id", .integer)
      table.column("reply_to_message_id", .integer)
      table.column("delivery_source", .text).notNull()
        .defaults(to: DeliverySource.run.rawValue)
      table.check(
        sql: "run_id IS NOT NULL OR delivery_source <> '\(DeliverySource.run.rawValue)'"
      )
    }
    // Columns are listed explicitly: a bare `SELECT *` would bind by position and silently
    // mis-seat every value if either table's column order ever drifted.
    try db.execute(
      sql: """
        INSERT INTO outbound_deliveries_new (run_id, step_index, chat_id, dedup_key, payload,
          payload_hash, telegram_message_id, status, created_ts, sent_ts, approval_id,
          reply_markup, message_thread_id, reply_to_message_id)
        SELECT run_id, step_index, chat_id, dedup_key, payload, payload_hash,
          telegram_message_id, status, created_ts, sent_ts, approval_id, reply_markup,
          message_thread_id, reply_to_message_id
        FROM outbound_deliveries
        """
    )
    try db.drop(table: "outbound_deliveries")
    try db.rename(table: "outbound_deliveries_new", to: "outbound_deliveries")
  }
}
