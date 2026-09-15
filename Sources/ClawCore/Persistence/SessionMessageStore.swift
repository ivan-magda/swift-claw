import Foundation

public enum Provenance: String, Sendable, Equatable {
  case trusted
  case untrusted
}

public enum MessageRole: String, Sendable, Equatable {
  case system
  case user
  case assistant
  case tool
}

public enum SessionKey {
  private static let dmPrefix = "tg:dm:"
  private static let topicPrefix = "tg:topic:"
  private static let jobPrefix = "sched:job:"

  /// The forum's General topic carries no `message_thread_id`, so its key needs a suffix that no
  /// thread id can ever produce. A numeric coercion (0, or topic 1) would fuse two distinct
  /// conversations into one session.
  private static let generalTopicSuffix = "general"

  /// The heartbeat's dedicated persistent session. No chat id in the key —
  /// the delivery target is resolved from config, so `chatID(from:)` stays nil by design.
  public static let heartbeat = "sched:heartbeat"

  public static func telegramDM(chatID: Int64) -> String { "\(dmPrefix)\(chatID)" }

  /// One session per forum topic. `threadID` is nil in the General topic and in a non-forum group,
  /// which both collapse onto the chat's single General key — correct, since a non-forum group has
  /// exactly one conversation.
  public static func telegramTopic(chatID: Int64, threadID: Int64?) -> String {
    let suffix = threadID.map(String.init) ?? generalTopicSuffix
    return "\(topicPrefix)\(chatID):\(suffix)"
  }

  /// The one place a key is minted from an inbound message. Routing resolves the mode once and
  /// every handler funnels through here, so a topic can never be dropped on one path and honored
  /// on another.
  public static func telegram(for message: IncomingMessage, mode: ChatMode) -> String {
    switch mode {
    case .direct: telegramDM(chatID: message.chatID)
    case .group: telegramTopic(chatID: message.chatID, threadID: message.messageThreadID)
    }
  }

  /// A job's dedicated session, created lazily at first fire. No chat id in the key —
  /// the delivery target is `scheduled_jobs.owner_chat_id`, so `chatID(from:)` stays nil by design.
  public static func scheduledJob(id: Int64) -> String { "\(jobPrefix)\(id)" }

  public static func chatID(from key: String) -> Int64? {
    if key.hasPrefix(dmPrefix) {
      return Int64(key.dropFirst(dmPrefix.count))
    }
    guard let body = topicBody(of: key), let separator = body.lastIndex(of: ":") else {
      return nil
    }
    return Int64(body[body.startIndex..<separator])
  }

  /// The mode a session is being served in, recovered from its key alone — the derivation every
  /// consumer that holds only a session id (and therefore only its key) depends on. Scheduled-job
  /// and heartbeat sessions are the owner's own, so they read `.direct`.
  public static func mode(from key: String) -> ChatMode {
    key.hasPrefix(topicPrefix) ? .group : .direct
  }

  /// The forum topic to deliver into, or nil for the General topic and for every non-topic key.
  public static func threadID(from key: String) -> Int64? {
    guard let body = topicBody(of: key), let separator = body.lastIndex(of: ":") else {
      return nil
    }
    return Int64(body[body.index(after: separator)...])
  }

  private static func topicBody(of key: String) -> Substring? {
    key.hasPrefix(topicPrefix) ? key.dropFirst(topicPrefix.count) : nil
  }
}

public struct InboundMessage: Sendable, Equatable {
  public let updateID: Int64
  public let sessionKey: String
  public let chatID: Int64
  public let userID: Int64
  public let text: String
  public let isEdited: Bool
  public let provenance: Provenance
  /// Telegram's id for the message that triggered this turn, nil for an inbound with no Telegram
  /// origin (a scheduled job). It is the reply target an answer addresses, and the fused claim is
  /// the only write that touches the run row it belongs on.
  public let telegramMessageID: Int64?
  public let ts: Date

  public init(
    updateID: Int64,
    sessionKey: String,
    chatID: Int64,
    userID: Int64,
    text: String,
    isEdited: Bool,
    provenance: Provenance = .trusted,
    telegramMessageID: Int64? = nil,
    ts: Date
  ) {
    self.updateID = updateID
    self.sessionKey = sessionKey
    self.chatID = chatID
    self.userID = userID
    self.text = text
    self.isEdited = isEdited
    self.provenance = provenance
    self.telegramMessageID = telegramMessageID
    self.ts = ts
  }
}

public struct ClaimResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionID: Int64?
  public let messageID: Int64?
  public let runID: Int64?
  public let triggerMessageID: Int64?

  public init(
    newlyClaimed: Bool,
    sessionID: Int64?,
    messageID: Int64?,
    runID: Int64?,
    triggerMessageID: Int64?
  ) {
    self.newlyClaimed = newlyClaimed
    self.sessionID = sessionID
    self.messageID = messageID
    self.runID = runID
    self.triggerMessageID = triggerMessageID
  }
}

public struct StoredMessage: Sendable, Equatable {
  public let role: MessageRole
  public let content: String
  public let provenance: Provenance
  public let toolCallsJSON: String?
  public let toolCallID: String?
  public let providerState: ProviderExchangeState?
  public let image: ImagePart?

  public init(
    role: MessageRole,
    content: String,
    provenance: Provenance,
    toolCallsJSON: String? = nil,
    toolCallID: String? = nil,
    providerState: ProviderExchangeState? = nil,
    image: ImagePart? = nil
  ) {
    self.role = role
    self.content = content
    self.provenance = provenance
    self.toolCallsJSON = toolCallsJSON
    self.toolCallID = toolCallID
    self.providerState = providerState
    self.image = image
  }
}

public struct SessionContextSnapshot: Sendable, Equatable {
  /// The owning session's key, carried so a consumer holding only a `sessionId` can still derive
  /// the chat mode and the forum topic without a second read.
  public let sessionKey: String
  public let history: [StoredMessage]
  public let historyMessageIDs: [Int64]
  public let windowStartMessageID: Int64?
  public let isTainted: Bool
  /// The persisted private-data flag, fed into the trifecta gate's private-data leg so the
  /// exfil gate stays armed even after the window rolls past the private read that set it.
  public let hasPrivateData: Bool

  public init(
    sessionKey: String,
    history: [StoredMessage],
    historyMessageIDs: [Int64],
    windowStartMessageID: Int64?,
    isTainted: Bool,
    hasPrivateData: Bool
  ) {
    self.sessionKey = sessionKey
    self.history = history
    self.historyMessageIDs = historyMessageIDs
    self.windowStartMessageID = windowStartMessageID
    self.isTainted = isTainted
    self.hasPrivateData = hasPrivateData
  }
}

public enum CommandClaim: Sendable, Equatable {
  case duplicate
  case claimed(sessionID: Int64)
}

public protocol SessionMessageStore: Sendable {
  func loadOrCreateSession(sessionKey: String, now: Date) throws(StoreError) -> Int64

  func claimCommandUpdate(updateID: Int64, sessionKey: String, now: Date) throws(StoreError)
    -> CommandClaim

  func findSession(sessionKey: String) throws(StoreError) -> Int64?

  /// Fused transaction: claim the update, upsert the session, insert the user message, create the
  /// PENDING run, and stamp its trigger message in one write. Duplicates create nothing.
  func claimAndPersistInbound(_ inbound: InboundMessage) throws(StoreError) -> ClaimResult

  /// The same fused write minus the run: claim the update, upsert the session, insert the user
  /// message. What a message the bot overheard rather than was asked deserves — it belongs in the
  /// room's history, but nothing is owed back, so `runId` and `triggerMessageId` come back nil.
  /// Shares the claim key with `claimAndPersistInbound`, so one update is stored exactly once
  /// whichever path it takes.
  func claimAndPersistObserved(_ inbound: InboundMessage) throws(StoreError) -> ClaimResult

  /// Context snapshot returned oldest-first and bounded to the message this run is answering.
  /// Includes the durable session metadata the assembler needs for recall dedup and taint reads.
  func loadContextSnapshot(sessionID: Int64, throughMessageID: Int64, limit: Int) throws(StoreError)
    -> SessionContextSnapshot
}
