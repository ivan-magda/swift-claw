import ClawCore
import Foundation

// MARK: - Session Message Store

/// Configurable `SessionMessageStore` double. Every operation first consults `failures` and throws
/// the error mapped to it, then delegates to `inner` when one is supplied, and otherwise returns a
/// benign default. One shape therefore covers a store that is wholly unavailable, a store with a
/// single broken operation, and a real store wrapped to break one operation.
public struct FakeSessionMessageStore: SessionMessageStore {
  public enum Operation: Sendable, Hashable, CaseIterable {
    case loadOrCreateSession
    case claimCommandUpdate
    case findSession
    case claimAndPersistInbound
    case loadContextSnapshot
    case resetWindowAndDetaint
  }

  /// The snapshot a delegate-less fake reads back: a session with no history, no taint and no
  /// private data, keyed to an arbitrary DM so consumers deriving a mode from it read `.direct`.
  public static let emptySnapshot = SessionContextSnapshot(
    sessionKey: SessionKey.telegramDM(chatId: 42),
    history: [],
    historyMessageIds: [],
    windowStartMessageId: nil,
    isTainted: false,
    hasPrivateData: false
  )

  private let failures: [Operation: StoreError]
  private let inner: (any SessionMessageStore)?
  private let snapshot: SessionContextSnapshot

  public init(
    failures: [Operation: StoreError] = [:],
    delegatingTo inner: (any SessionMessageStore)? = nil,
    snapshot: SessionContextSnapshot = FakeSessionMessageStore.emptySnapshot
  ) {
    self.failures = failures
    self.inner = inner
    self.snapshot = snapshot
  }

  /// A store no operation can reach — the shape a full disk or a lost database file presents.
  public static func failingEverything(with error: StoreError) -> FakeSessionMessageStore {
    FakeSessionMessageStore(
      failures: Dictionary(uniqueKeysWithValues: Operation.allCases.map { ($0, error) })
    )
  }

  public func loadOrCreateSession(sessionKey: String, now: Date) throws(StoreError) -> Int64 {
    if let error = failures[.loadOrCreateSession] {
      throw error
    }
    guard let inner else {
      return 0
    }
    return try inner.loadOrCreateSession(sessionKey: sessionKey, now: now)
  }

  public func claimCommandUpdate(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws(StoreError) -> CommandClaim {
    if let error = failures[.claimCommandUpdate] {
      throw error
    }
    guard let inner else {
      return .duplicate
    }
    return try inner.claimCommandUpdate(updateId: updateId, sessionKey: sessionKey, now: now)
  }

  public func findSession(sessionKey: String) throws(StoreError) -> Int64? {
    if let error = failures[.findSession] {
      throw error
    }
    return try inner?.findSession(sessionKey: sessionKey)
  }

  public func claimAndPersistInbound(_ inbound: InboundMessage) throws(StoreError) -> ClaimResult {
    if let error = failures[.claimAndPersistInbound] {
      throw error
    }
    guard let inner else {
      return ClaimResult(
        newlyClaimed: false,
        sessionId: nil,
        messageId: nil,
        runId: nil,
        triggerMessageId: nil
      )
    }
    return try inner.claimAndPersistInbound(inbound)
  }

  public func loadContextSnapshot(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws(StoreError) -> SessionContextSnapshot {
    if let error = failures[.loadContextSnapshot] {
      throw error
    }
    guard let inner else {
      return snapshot
    }
    return try inner.loadContextSnapshot(
      sessionId: sessionId,
      throughMessageId: throughMessageId,
      limit: limit
    )
  }

  public func resetWindowAndDetaint(sessionId: Int64, now: Date) throws(StoreError) {
    if let error = failures[.resetWindowAndDetaint] {
      throw error
    }
    try inner?.resetWindowAndDetaint(sessionId: sessionId, now: now)
  }
}
