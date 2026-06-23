import Foundation

public enum RunState: String, Sendable, Equatable {
  case pending = "PENDING"
  case running = "RUNNING"
  case done = "DONE"
  case failed = "FAILED"
}

public enum Provenance: String, Sendable, Equatable {
  case trusted
  case untrusted
}

public enum MessageRole: String, Sendable, Equatable {
  case system
  case user
  case assistant
}

public enum CostSource: String, Sendable, Equatable {
  case providerReturned = "provider_returned"
  case priceFile = "price_file"
  case heuristic
}

public enum SessionKey {
  private static let dmPrefix = "tg:dm:"

  public static func telegramDM(chatId: Int64) -> String {
    "\(dmPrefix)\(chatId)"
  }

  public static func chatId(from key: String) -> Int64? {
    key.hasPrefix(dmPrefix) ? Int64(key.dropFirst(dmPrefix.count)) : nil
  }
}

public struct InboundMessage: Sendable, Equatable {
  public let updateId: Int64
  public let sessionKey: String
  public let chatId: Int64
  public let userId: Int64
  public let text: String
  /// Carried through from the Telegram update; the gateway consumes it in a later increment.
  public let isEdited: Bool
  public let ts: Date

  public init(
    updateId: Int64,
    sessionKey: String,
    chatId: Int64,
    userId: Int64,
    text: String,
    isEdited: Bool,
    ts: Date
  ) {
    self.updateId = updateId
    self.sessionKey = sessionKey
    self.chatId = chatId
    self.userId = userId
    self.text = text
    self.isEdited = isEdited
    self.ts = ts
  }
}

public struct ClaimResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionId: Int64?
  public let messageId: Int64?

  public init(newlyClaimed: Bool, sessionId: Int64?, messageId: Int64?) {
    self.newlyClaimed = newlyClaimed
    self.sessionId = sessionId
    self.messageId = messageId
  }
}

public struct StoredMessage: Sendable, Equatable {
  public let role: MessageRole
  public let content: String
  public let provenance: Provenance

  public init(role: MessageRole, content: String, provenance: Provenance) {
    self.role = role
    self.content = content
    self.provenance = provenance
  }
}

public struct ProviderUsage: Sendable, Equatable {
  public let runId: Int64
  public let sessionId: Int64
  public let model: String
  public let promptTokens: Int
  public let completionTokens: Int
  public let costUSD: Double
  public let costSource: CostSource
  public let isEstimated: Bool
  public let ts: Date

  public init(
    runId: Int64,
    sessionId: Int64,
    model: String,
    promptTokens: Int,
    completionTokens: Int,
    costUSD: Double,
    costSource: CostSource,
    isEstimated: Bool,
    ts: Date
  ) {
    self.runId = runId
    self.sessionId = sessionId
    self.model = model
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.costUSD = costUSD
    self.costSource = costSource
    self.isEstimated = isEstimated
    self.ts = ts
  }
}

public struct OutboxChunk: Sendable, Equatable {
  public let stepIndex: Int
  public let chatId: Int64
  public let payload: String
  public let payloadHash: String

  public init(stepIndex: Int, chatId: Int64, payload: String, payloadHash: String) {
    self.stepIndex = stepIndex
    self.chatId = chatId
    self.payload = payload
    self.payloadHash = payloadHash
  }
}

public struct OutboxRow: Sendable, Equatable {
  public let runId: Int64
  public let stepIndex: Int
  public let chatId: Int64
  public let payload: String

  public init(runId: Int64, stepIndex: Int, chatId: Int64, payload: String) {
    self.runId = runId
    self.stepIndex = stepIndex
    self.chatId = chatId
    self.payload = payload
  }
}

public struct AssistantTurn: Sendable, Equatable {
  public let runId: Int64
  public let sessionId: Int64
  public let chatId: Int64
  public let content: String
  public let usage: ProviderUsage
  public let chunks: [OutboxChunk]

  public init(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    content: String,
    usage: ProviderUsage,
    chunks: [OutboxChunk]
  ) {
    self.runId = runId
    self.sessionId = sessionId
    self.chatId = chatId
    self.content = content
    self.usage = usage
    self.chunks = chunks
  }
}

/// Who an audit event is attributed to. A small closed set so the audit trail can't record a
/// typo'd actor; persisted via `rawValue` at the store seam.
public enum AuditActor: String, Sendable, Equatable {
  case owner
  case assistant
  case system
}

/// The category of an audit event (the specific tool/reason rides in `tool`/`decision`, not here).
/// Closed by design: a controlled vocabulary makes the audit log queryable and typo-proof. Add a
/// case when a new kind of event needs recording.
public enum AuditAction: String, Sendable, Equatable {
  case messageIn = "message_in"
  case toolCall = "tool_call"
  case turnCompleted = "turn_completed"
  case turnDegraded = "turn_degraded"
  case turnBudgetStopped = "turn_budget_stopped"
  case budgetTripped = "budget_tripped"
}

public struct AuditEvent: Sendable, Equatable {
  public let actor: AuditActor
  public let action: AuditAction
  public let tool: String?
  public let argsRedacted: String
  public let resultSize: Int
  public let decision: String
  public let runId: Int64?
  public let sessionId: Int64?
  public let ts: Date

  public init(
    actor: AuditActor,
    action: AuditAction,
    tool: String? = nil,
    argsRedacted: String = "",
    resultSize: Int = 0,
    decision: String = "ok",
    runId: Int64? = nil,
    sessionId: Int64? = nil,
    ts: Date
  ) {
    self.actor = actor
    self.action = action
    self.tool = tool
    self.argsRedacted = argsRedacted
    self.resultSize = resultSize
    self.decision = decision
    self.runId = runId
    self.sessionId = sessionId
    self.ts = ts
  }
}

public struct DegradationReply: Sendable, Equatable {
  public let chatId: Int64
  public let runId: Int64
  public let text: String

  public init(chatId: Int64, runId: Int64, text: String) {
    self.chatId = chatId
    self.runId = runId
    self.text = text
  }
}
