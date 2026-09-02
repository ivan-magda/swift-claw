import Foundation

public protocol OutboxStore: Sendable {
  func claimOutbound(runId: Int64, chunk: OutboxChunk) throws(StoreError) -> Bool
  /// Enqueues one chunk of an owner-facing learning notice, which belongs to no run. Idempotent on
  /// the chunk's own delivery key, so a retried enqueue never duplicates the message.
  func claimNotice(_ chunk: LearningNoticeChunk) throws(StoreError) -> Bool
  func markSent(deliveryKey: String, telegramMessageId: Int64, now: Date) throws(StoreError)
  func pendingOutbound() throws(StoreError) -> [OutboxRow]
}
