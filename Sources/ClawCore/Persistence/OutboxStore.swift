import Foundation

public protocol OutboxStore: Sendable {
  func claimOutbound(runId: Int64, chunk: OutboxChunk) throws(StoreError) -> Bool
  /// Enqueues one gateway-authored line onto a run's delivery sequence MID-RUN, extending it from
  /// the run's next free step. Its own step is never a literal: a run that already committed a
  /// prompt or an earlier line holds those steps, and the dedup key would drop a colliding chunk
  /// silently. Returns whether a row was inserted.
  func enqueueNotice(runId: Int64, chatId: Int64, text: String) throws(StoreError) -> Bool
  func markSent(
    runId: Int64,
    stepIndex: Int,
    telegramMessageId: Int64,
    now: Date
  ) throws(StoreError)
  func pendingOutbound() throws(StoreError) -> [OutboxRow]
}
