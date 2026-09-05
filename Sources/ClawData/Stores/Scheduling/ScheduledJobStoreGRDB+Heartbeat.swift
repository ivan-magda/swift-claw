import ClawCore
import Foundation
import GRDB

// MARK: - Scheduler State

extension ScheduledJobStoreGRDB {
  public func schedulerState() throws(StoreError) -> SchedulerState {
    try database.readMapping { db in
      guard
        let row = try Row.fetchOne(db, sql: "SELECT * FROM scheduler_state WHERE id = 1")
      else {
        return SchedulerState(
          lastTickAt: nil,
          lastMisfireAt: nil,
          lastMisfireSkippedCount: 0,
          lastHeartbeatAt: nil,
          heartbeatCountDay: nil,
          heartbeatCount: 0
        )
      }
      return SchedulerState(
        lastTickAt: EpochSecondCodec.date(fromEpoch: row["last_tick_at"]),
        lastMisfireAt: EpochSecondCodec.date(fromEpoch: row["last_misfire_at"]),
        lastMisfireSkippedCount: row["last_misfire_skipped_count"],
        lastHeartbeatAt: EpochSecondCodec.date(fromEpoch: row["last_heartbeat_at"]),
        heartbeatCountDay: row["heartbeat_count_day"],
        heartbeatCount: row["heartbeat_count"]
      )
    }
  }

  public func recordTick(at tickTime: Date) throws(StoreError) {
    try database.writeMapping { db in
      try db.execute(
        sql: """
          INSERT INTO scheduler_state(id, last_tick_at) VALUES (1, ?)
          ON CONFLICT(id) DO UPDATE SET last_tick_at = excluded.last_tick_at
          """,
        arguments: [EpochSecondCodec.epoch(tickTime)]
      )
    }
  }
}

// MARK: - Heartbeat Fire (the gating lives in SchedulerService)

extension ScheduledJobStoreGRDB {
  // swiftlint:disable:next function_body_length
  public func fireHeartbeat(
    prompt: String,
    ownerChatId: Int64,
    now: Date,
    day: String
  ) throws(StoreError) -> ClaimedFire? {
    try database.writeMapping { db in
      let sessionId = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: SessionKey.heartbeat,
        now: now
      )

      // Same overlap guard as a job fire: a prior beat still in flight owns the shared heartbeat
      // window; resetting it here would empty that beat's context on resume. Skip this beat by
      // returning nil — overlap is fireHeartbeat's only nil reason, so nil alone carries the
      // signal. The caller records the canonical heartbeat_skipped audit (reason in `decision`).
      if try RunStoreGRDB.hasLiveRun(db, sessionId: sessionId) {
        return nil
      }

      // Same per-fire isolation as a job fire: each beat starts on a fresh window of the
      // persistent heartbeat session.
      try SessionMessageStoreGRDB.resetWindowAndDetaint(db, sessionId: sessionId, now: now)

      // The gateway-authored template WRAPS HEARTBEAT.md content, so the combined trigger text
      // carries the untrusted tier — workspace-file data must never enter context as trusted
      // (contrast the scheduled-job trigger, which is pure owner-confirmed text).
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId,
          MessageRole.user.rawValue,
          prompt,
          Provenance.untrusted.rawValue,
          now,
        ]
      )
      let triggerMessageId = db.lastInsertedRowID

      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id, origin)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId,
          RunState.pending.rawValue,
          now,
          now,
          triggerMessageId,
          RunOrigin.heartbeat.rawValue,
        ]
      )
      let runId = db.lastInsertedRowID

      // Day-counter roll: same `day` increments; a new `day` resets to 1. `day` is computed by
      // the caller in CLAW_TIMEZONE so the cap boundary aligns with quiet hours, not UTC.
      let previous = try Row.fetchOne(
        db,
        sql: "SELECT heartbeat_count_day, heartbeat_count FROM scheduler_state WHERE id = 1"
      )
      let previousDay = previous?["heartbeat_count_day"] as String?
      let previousCount = previous?["heartbeat_count"] as Int? ?? 0
      let newCount = previousDay == day ? previousCount + 1 : 1
      try db.execute(
        sql: """
          INSERT INTO scheduler_state(id, last_heartbeat_at, heartbeat_count_day, heartbeat_count)
          VALUES (1, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            last_heartbeat_at = excluded.last_heartbeat_at,
            heartbeat_count_day = excluded.heartbeat_count_day,
            heartbeat_count = excluded.heartbeat_count
          """,
        arguments: [EpochSecondCodec.epoch(now), day, newCount]
      )

      return ClaimedFire(
        runId: runId,
        sessionId: sessionId,
        triggerMessageId: triggerMessageId,
        ownerChatId: ownerChatId
      )
    }
  }
}
