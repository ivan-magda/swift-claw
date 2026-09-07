import Foundation

public enum CoderJobState: String, Sendable, Codable {
  case admitted, running, stopping, succeeded, failed, cancelled, timedOut, interrupted

  public var isTerminal: Bool {
    switch self {
    case .admitted, .running, .stopping: false
    case .succeeded, .failed, .cancelled, .timedOut, .interrupted: true
    }
  }
}

public struct CoderOrigin: Sendable, Equatable, Codable {
  public let runID: Int64
  public let sessionID: Int64
  public let requesterUserID: Int64
  public let chatID: Int64
  public let toolCallID: String
  public let approvalID: Int64

  public init(
    runID: Int64,
    sessionID: Int64,
    requesterUserID: Int64,
    chatID: Int64,
    toolCallID: String,
    approvalID: Int64
  ) {
    self.runID = runID
    self.sessionID = sessionID
    self.requesterUserID = requesterUserID
    self.chatID = chatID
    self.toolCallID = toolCallID
    self.approvalID = approvalID
  }
}

public enum CoderProcessPhase: String, Sendable, Codable { case prepare, codex, inspect }

public enum CoderProcessOwnership: String, Sendable, Codable {
  case none, launching, owned, stopped, unresolved
}

public struct CoderProcessReceipt: Sendable, Equatable, Codable {
  public let launchID: UUID
  public let phase: CoderProcessPhase
  public let hostBootID: String
  public let pid: Int32?
  public let pgid: Int32?
  public let birthIdentity: String?

  public init(
    launchID: UUID,
    phase: CoderProcessPhase,
    hostBootID: String,
    pid: Int32?,
    pgid: Int32?,
    birthIdentity: String?
  ) {
    self.launchID = launchID
    self.phase = phase
    self.hostBootID = hostBootID
    self.pid = pid
    self.pgid = pgid
    self.birthIdentity = birthIdentity
  }
}

public enum CoderProcessEvent: Sendable {
  case willLaunch(CoderProcessReceipt)
  case didLaunch(CoderProcessReceipt)
  case stopped(launchID: UUID)
  case unresolved(launchID: UUID)
}

public struct CoderJob: Sendable, Equatable, Codable {
  public let id: UUID
  public let origin: CoderOrigin
  public let prepared: CoderPreparedRequest
  public let state: CoderJobState
  public let createdAt: Date
  public let slotReserved: Bool
  public let ownership: CoderProcessOwnership
  public let processReceipt: CoderProcessReceipt?
  public let result: CoderResult?

  public init(
    id: UUID,
    origin: CoderOrigin,
    prepared: CoderPreparedRequest,
    state: CoderJobState,
    createdAt: Date,
    slotReserved: Bool,
    ownership: CoderProcessOwnership,
    processReceipt: CoderProcessReceipt?,
    result: CoderResult?
  ) {
    self.id = id
    self.origin = origin
    self.prepared = prepared
    self.state = state
    self.createdAt = createdAt
    self.slotReserved = slotReserved
    self.ownership = ownership
    self.processReceipt = processReceipt
    self.result = result
  }
}
