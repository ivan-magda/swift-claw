import Foundation

public enum CommandClaim: Sendable, Equatable {
  case duplicate
  case claimed(sessionId: Int64)
}

public protocol SessionMessageStore: Sendable {
  func loadOrCreateSession(sessionKey: String, now: Date) throws(StoreError) -> Int64
  func claimCommandUpdate(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws(StoreError) -> CommandClaim
  func findSession(sessionKey: String) throws(StoreError) -> Int64?
  /// Fused transaction: claim the update, upsert the session, insert the user message, create the
  /// PENDING run, and stamp its trigger message in one write. Duplicates create nothing.
  func claimAndPersistInbound(
    _ inbound: InboundMessage
  ) throws(StoreError) -> ClaimResult
  /// Context snapshot returned oldest-first and bounded to the message this run is answering.
  /// Includes the durable session metadata the assembler needs for recall dedup and taint reads.
  func loadContextSnapshot(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws(StoreError) -> SessionContextSnapshot
  /// Advances the `/new` context boundary to the latest message and clears session taint.
  func resetWindowAndDetaint(sessionId: Int64, now: Date) throws(StoreError)
}
