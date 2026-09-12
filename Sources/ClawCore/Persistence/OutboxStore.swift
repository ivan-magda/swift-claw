import Foundation

public struct OutboxChunk: Sendable, Equatable {
  public let stepIndex: Int
  public let chatId: Int64
  public let payload: String
  public let payloadHash: String
  public let approvalId: Int64?
  public let replyMarkup: String?

  public init(
    stepIndex: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String,
    approvalId: Int64? = nil,
    replyMarkup: String? = nil
  ) {
    self.stepIndex = stepIndex
    self.chatId = chatId
    self.payload = payload
    self.payloadHash = payloadHash
    self.approvalId = approvalId
    self.replyMarkup = replyMarkup
  }
}

public enum DeliverySource: String, Sendable, Equatable, CaseIterable {
  case run
  case learning
  case conference
}

public struct LearningNoticeChunk: Sendable, Equatable {
  public let subjectDigest: String
  public let ordinal: Int
  public let chatId: Int64
  public let payload: String
  public let payloadHash: String
  public let replyMarkup: String?

  public init(
    subjectDigest: String,
    ordinal: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String,
    replyMarkup: String? = nil
  ) {
    self.subjectDigest = subjectDigest
    self.ordinal = ordinal
    self.chatId = chatId
    self.payload = payload
    self.payloadHash = payloadHash
    self.replyMarkup = replyMarkup
  }
}

/// Runless completion notice for one immutable conference submission.
public struct ConferenceNoticeChunk: Sendable, Equatable {
  public let submissionID: UUID
  public let originRunID: Int64
  public let ordinal: Int
  public let chatId: Int64
  public let payload: String
  public let payloadHash: String

  public init(
    submissionID: UUID,
    originRunID: Int64,
    ordinal: Int,
    chatId: Int64,
    payload: String,
    payloadHash: String
  ) {
    self.submissionID = submissionID
    self.originRunID = originRunID
    self.ordinal = ordinal
    self.chatId = chatId
    self.payload = payload
    self.payloadHash = payloadHash
  }
}

public struct OutboxRow: Sendable, Equatable {
  public let deliveryKey: String
  public let runId: Int64?
  public let stepIndex: Int
  public let chatId: Int64
  public let payload: String
  public let approvalId: Int64?
  public let replyMarkup: String?
  public let messageThreadId: Int64?
  public let replyToMessageId: Int64?

  public var target: DeliveryTarget {
    DeliveryTarget(
      chatId: chatId,
      messageThreadId: messageThreadId,
      replyToMessageId: replyToMessageId
    )
  }

  public var originLabel: String {
    if let runId {
      return String(runId)
    }
    // Keep existing learning diagnostics while recognizing the namespaced conference subject.
    return deliveryKey.hasPrefix("learning:conference:")
      ? DeliverySource.conference.rawValue : DeliverySource.learning.rawValue
  }

  public init(
    deliveryKey: String,
    runId: Int64?,
    stepIndex: Int,
    chatId: Int64,
    payload: String,
    approvalId: Int64? = nil,
    replyMarkup: String? = nil,
    messageThreadId: Int64? = nil,
    replyToMessageId: Int64? = nil
  ) {
    self.deliveryKey = deliveryKey
    self.runId = runId
    self.stepIndex = stepIndex
    self.chatId = chatId
    self.payload = payload
    self.approvalId = approvalId
    self.messageThreadId = messageThreadId
    self.replyToMessageId = replyToMessageId
    self.replyMarkup = replyMarkup
  }
}

public protocol OutboxStore: Sendable {
  func claimOutbound(runId: Int64, chunk: OutboxChunk) throws(StoreError) -> Bool
  func claimNotice(_ chunk: LearningNoticeChunk) throws(StoreError) -> Bool
  func claimConferenceNotice(_ chunk: ConferenceNoticeChunk) throws(StoreError) -> Bool
  func markSent(deliveryKey: String, telegramMessageId: Int64, now: Date) throws(StoreError)
  func pendingOutbound() throws(StoreError) -> [OutboxRow]
}

/// Source-compatible fallback for existing test doubles that never exercise conference delivery.
public extension OutboxStore {
  func claimConferenceNotice(_ chunk: ConferenceNoticeChunk) throws(StoreError) -> Bool {
    throw StoreError.unexpected("Conference notices are not supported by this outbox")
  }
}
