import Foundation

public enum ConferenceToolNames {
  public static let current = "challenge_current"
  public static let submit = "challenge_submit"
  public static let status = "challenge_status"
}

public enum ConferenceSubmissionState: String, Sendable, Codable, CaseIterable {
  case queued
  case running
  case completed
  case blocked
  case failed
  case cancelled
  case needsReview = "needs_review"

  public var isTerminal: Bool {
    switch self {
    case .queued, .running: false
    case .completed, .blocked, .failed, .cancelled, .needsReview: true
    }
  }
}

public struct ConferenceCase: Sendable, Equatable, Codable {
  public let id: String
  public let title: String
  public let prompt: String
  public let repositoryURL: String
  public let baselineRef: String
  public let baseBranch: String

  public init(
    id: String,
    title: String,
    prompt: String,
    repositoryURL: String,
    baselineRef: String,
    baseBranch: String
  ) {
    self.id = id
    self.title = title
    self.prompt = prompt
    self.repositoryURL = repositoryURL
    self.baselineRef = baselineRef
    self.baseBranch = baseBranch
  }
}

public struct ConferenceApprovedOrigin: Sendable, Equatable, Codable {
  public let runID: Int64
  public let sessionID: Int64
  public let chatID: Int64
  public let requesterUserID: Int64
  public let mode: ChatMode
  public let toolCallID: String
  public let approvalID: Int64

  public init(
    runID: Int64,
    sessionID: Int64,
    chatID: Int64,
    requesterUserID: Int64,
    mode: ChatMode,
    toolCallID: String,
    approvalID: Int64
  ) {
    self.runID = runID
    self.sessionID = sessionID
    self.chatID = chatID
    self.requesterUserID = requesterUserID
    self.mode = mode
    self.toolCallID = toolCallID
    self.approvalID = approvalID
  }

  public init?(context: ToolExecutionContext) {
    guard context.origin == .interactive,
      let requester = context.requesterUserId, requester > 0,
      let approval = context.approvalId
    else {
      return nil
    }
    self.init(
      runID: context.runId,
      sessionID: context.sessionId,
      chatID: context.chatId,
      requesterUserID: requester,
      mode: context.mode,
      toolCallID: context.toolCallId,
      approvalID: approval
    )
  }

  public var executionContext: ToolExecutionContext {
    ToolExecutionContext(
      runId: runID,
      sessionId: sessionID,
      chatId: chatID,
      requesterUserId: requesterUserID,
      origin: .interactive,
      mode: mode,
      toolCallId: toolCallID,
      approvalId: approvalID
    )
  }

  private enum CodingKeys: String, CodingKey {
    case runID
    case sessionID
    case chatID
    case requesterUserID
    case mode
    case toolCallID
    case approvalID
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let modeValue = try values.decode(String.self, forKey: .mode)
    guard let mode = ChatMode(rawValue: modeValue) else {
      throw DecodingError.dataCorruptedError(
        forKey: .mode,
        in: values,
        debugDescription: "Unknown conference chat mode"
      )
    }
    self.init(
      runID: try values.decode(Int64.self, forKey: .runID),
      sessionID: try values.decode(Int64.self, forKey: .sessionID),
      chatID: try values.decode(Int64.self, forKey: .chatID),
      requesterUserID: try values.decode(Int64.self, forKey: .requesterUserID),
      mode: mode,
      toolCallID: try values.decode(String.self, forKey: .toolCallID),
      approvalID: try values.decode(Int64.self, forKey: .approvalID)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(runID, forKey: .runID)
    try values.encode(sessionID, forKey: .sessionID)
    try values.encode(chatID, forKey: .chatID)
    try values.encode(requesterUserID, forKey: .requesterUserID)
    try values.encode(mode.rawValue, forKey: .mode)
    try values.encode(toolCallID, forKey: .toolCallID)
    try values.encode(approvalID, forKey: .approvalID)
  }
}

public struct PreparedConferenceSubmission: Sendable, Equatable, Codable {
  public let caseSnapshot: ConferenceCase
  public let answer: String

  public init(caseSnapshot: ConferenceCase, answer: String) {
    self.caseSnapshot = caseSnapshot
    self.answer = answer
  }
}

public struct ConferenceSubmission: Sendable, Equatable, Codable {
  public let id: UUID
  public let participantUserID: Int64
  public let caseSnapshot: ConferenceCase
  public let answer: String
  public let origin: ConferenceApprovedOrigin
  public let state: ConferenceSubmissionState
  public let coderJobID: UUID?
  public let pullRequestURL: String?
  public let branch: String?
  public let commit: String?
  public let failureReason: String?
  public let notificationEnqueued: Bool
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    participantUserID: Int64,
    caseSnapshot: ConferenceCase,
    answer: String,
    origin: ConferenceApprovedOrigin,
    state: ConferenceSubmissionState,
    coderJobID: UUID?,
    pullRequestURL: String?,
    branch: String?,
    commit: String?,
    failureReason: String?,
    notificationEnqueued: Bool = false,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.participantUserID = participantUserID
    self.caseSnapshot = caseSnapshot
    self.answer = answer
    self.origin = origin
    self.state = state
    self.coderJobID = coderJobID
    self.pullRequestURL = pullRequestURL
    self.branch = branch
    self.commit = commit
    self.failureReason = failureReason
    self.notificationEnqueued = notificationEnqueued
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum ConferenceError: Error, Sendable, Equatable {
  case disabled
  case noActiveCase
  case invalidAnswer(String)
  case answerMismatch
  case invalidContext
  case duplicateSubmission(UUID)
  case notFound
  case forbidden
  case staleCase
  case coderUnavailable(String)
}
