import Foundation

public protocol OutboxStore: Sendable {
  func claimOutbound(runId: Int64, chunk: OutboxChunk) throws -> Bool
  /// Claims a reply only while the owning run is still active (RUNNING or AWAITING_APPROVAL —
  /// a suspended run's own approval prompt must be deliverable).
  func claimOutboundIfRunActive(runId: Int64, chunk: OutboxChunk) throws -> Bool
  func markSent(runId: Int64, stepIndex: Int, telegramMessageId: Int64, now: Date)
    throws
  func pendingOutbound() throws -> [OutboxRow]
}
