import ClawCore
import Foundation
import GRDB

public struct RunStoreGRDB: RunStore {
  let database: MappedDatabase
  let suspendCommitFault: @Sendable () throws -> Void
  let claimedFillFault: @Sendable () throws -> Void

  public init(writer: any DatabaseWriter) {
    self.init(writer: writer, suspendCommitFault: {}, claimedFillFault: {})
  }

  init(
    writer: any DatabaseWriter,
    suspendCommitFault: @escaping @Sendable () throws -> Void,
    claimedFillFault: @escaping @Sendable () throws -> Void = {}
  ) {
    database = MappedDatabase(writer: writer)
    self.suspendCommitFault = suspendCommitFault
    self.claimedFillFault = claimedFillFault
  }
}

// MARK: - Run Lifecycle

extension RunStoreGRDB {
  public func pickUp(
    runId: Int64,
    policyVersion: String?,
    now: Date
  ) throws(StoreError) -> RunOrigin? {
    try database.writeMapping { db in
      guard
        try Self.transitionRun(
          db,
          runId: runId,
          event: .pickUp,
          now: now,
          policyVersion: policyVersion,
          terminal: nil
        ) != nil
      else {
        return nil
      }

      let rawOrigin = try String.fetchOne(
        db,
        sql: "SELECT origin FROM runs WHERE id = ?",
        arguments: [runId]
      )
      // Fail closed on a corrupted origin (same rule as decodeItem): a mislabeled origin would
      // silently re-route budget pools and delivery policy. The throw rolls back the pickUp
      // transition, so the run stays PENDING for the boot sweep.
      guard let rawOrigin, let origin = RunOrigin(rawValue: rawOrigin) else {
        throw StoreError.unexpected("runs row \(runId) has an unrecognized origin")
      }

      return origin
    }
  }

  public func cancelActiveRun(
    sessionId: Int64,
    reason: CancelReason,
    now: Date
  ) throws(StoreError) -> Int64? {
    try database.writeMapping { db in
      guard let runId = try Self.fetchActiveRunId(db, sessionId: sessionId) else {
        return nil
      }

      // Deferred, not settled: the round the command interrupted may still record its usage.
      guard
        try Self.transitionRun(
          db,
          runId: runId,
          event: reason.runEvent,
          now: now,
          terminal: .deferred(reason.terminalCause)
        ) != nil
      else {
        return nil
      }

      return runId
    }
  }

  public func supersedeSessionRuns(sessionId: Int64, now: Date) throws(StoreError) -> [Int64] {
    try database.writeMapping { db in
      try Self.supersedeRuns(db, sessionId: sessionId, now: now)
    }
  }

  public func failRun(runId: Int64, cause: TerminalCause, now: Date) throws(StoreError) {
    try database.writeMapping { db in
      guard
        try Self.transitionRun(
          db,
          runId: runId,
          event: .fail,
          now: now,
          terminal: .settled(cause)
        ) != nil
      else {
        return
      }
      try Self.appendJobFailedIfJobRun(db, runId: runId, now: now)
    }
  }

  public func resolveDeniedObservation(
    runId: Int64,
    observationMessageId: Int64,
    content: String,
    cancel: CancelReason?,
    now: Date
  ) throws(StoreError) -> RunCommitResult {
    try database.writeMapping { db in
      // Fill the placeholder observation in place: both `ContextBuilder.historyGroups` and
      // `HistoryHygiene` require every anchor's tool rows to be answered, so a dangling
      // "awaiting owner approval" row would drop the whole exchange from the next assembly. The
      // UPDATE is by message id — idempotent on a boot re-park, and correct for the /stop//new
      // path where the command transaction moved the run but never touched this row.
      try db.execute(
        sql: "UPDATE messages SET content = ? WHERE id = ?",
        arguments: [content, observationMessageId]
      )

      // The owner-deny arm settles: the placeholder above was this run's last owed fact. The
      // command arm defers like every other `/stop`//`new` termination.
      let event = cancel?.runEvent ?? .resolveDenied
      let terminal =
        cancel.map { reason in
          TerminalDisposition.deferred(reason.terminalCause)
        } ?? .settled(.approvalDenied)
      // For the command path the run is already CANCELLED/SUPERSEDED, so the FSM returns nil and we
      // report `.ignored`: the observation fix above was the only remaining work.
      guard
        let nextState = try Self.transitionRun(
          db,
          runId: runId,
          event: event,
          now: now,
          terminal: terminal
        )
      else {
        return .ignored
      }
      if nextState == .failed {
        try Self.appendJobFailedIfJobRun(db, runId: runId, now: now)
      }
      return .committed
    }
  }
}
