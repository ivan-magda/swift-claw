import ClawCore
import Foundation
import GRDB

extension CoderJobStoreGRDB {
  public func complete(  // swiftlint:disable:this function_parameter_count
    id: UUID,
    expectedState: CoderJobState,
    result: CoderResult,
    chunks: [OutboxChunk],
    releaseReservation: Bool,
    now: Date
  ) throws(StoreError) -> CoderCompletionOutcome {
    try database.writeMapping { db in
      guard let job = try CoderJobRecord.fetch(db, id: id) else {
        throw StoreError.unexpected("Coder completion has no job")
      }
      guard !job.state.isTerminal else {
        return .alreadyTerminal
      }
      guard job.state == expectedState else {
        return .stateChanged(job)
      }
      guard result.state.isTerminal else {
        throw StoreError.unexpected("Coder completion requires a terminal result")
      }
      if releaseReservation {
        try Self.requireResolvedOwnership(job)
      }
      try db.execute(
        sql: """
          UPDATE coder_jobs SET state = ?, result_json = ?, slot_reserved = ?, updated_ts = ?
          WHERE id = ?
          """,
        arguments: [
          result.state.rawValue, try CoderJobRecord.encodeJSON(result),
          releaseReservation ? false : job.slotReserved, EpochSecondCodec.epoch(now), id.uuidString,
        ]
      )
      try Self.insertCompletion(db, job: job, chunks: chunks, now: now)
      return .committed
    }
  }

  public func releaseResolvedReservation(id: UUID, now: Date) throws(StoreError) {
    try database.writeMapping { db in
      guard let job = try CoderJobRecord.fetch(db, id: id), job.state.isTerminal else {
        throw StoreError.unexpected("Coder reservation release requires a terminal job")
      }
      try Self.requireResolvedOwnership(job)
      try db.execute(
        sql: "UPDATE coder_jobs SET slot_reserved = 0, updated_ts = ? WHERE id = ?",
        arguments: [EpochSecondCodec.epoch(now), id.uuidString]
      )
    }
  }
}

// MARK: - Completion Transaction

private extension CoderJobStoreGRDB {
  static func requireResolvedOwnership(_ job: CoderJob) throws {
    guard job.ownership == .none || job.ownership == .stopped else {
      throw StoreError.unexpected("Coder process ownership must resolve before releasing its slot")
    }
  }

  static func insertCompletion(
    _ db: Database,
    job: CoderJob,
    chunks: [OutboxChunk],
    now: Date
  ) throws {
    let base = try OutboxInsertion.nextOutboxStepBase(db, runId: job.origin.runID)
    for chunk in chunks {
      let addressed = OutboxChunk(
        stepIndex: chunk.stepIndex,
        chatId: job.origin.chatID,
        payload: chunk.payload,
        payloadHash: chunk.payloadHash,
        approvalId: chunk.approvalId,
        replyMarkup: chunk.replyMarkup
      )
      let inserted = try OutboxInsertion.insertOutbox(
        db,
        runId: job.origin.runID,
        chunk: OutboxInsertion.shiftedChunk(addressed, by: base),
        now: now
      )
      guard inserted else {
        throw StoreError.unexpected("Coder completion notice collided with an existing delivery")
      }
    }
  }
}
