import Foundation

public struct OutboxChunk: Sendable, Equatable {
  public let stepIndex: Int
  public let chatID: Int64
  public let payload: String
  public let payloadHash: String
  public let approvalID: Int64?
  public let replyMarkup: String?

  public init(
    stepIndex: Int,
    chatID: Int64,
    payload: String,
    payloadHash: String,
    approvalID: Int64? = nil,
    replyMarkup: String? = nil
  ) {
    self.stepIndex = stepIndex
    self.chatID = chatID
    self.payload = payload
    self.payloadHash = payloadHash
    self.approvalID = approvalID
    self.replyMarkup = replyMarkup
  }
}

/// Which producer enqueued an outbound row. A run's chunks carry its id; a learning notice belongs
/// to no run, so the source column is what tells the two apart in storage.
public enum DeliverySource: String, Sendable, Equatable, CaseIterable {
  case run
  case learning
}

/// One chunk of an owner-facing learning notice. It belongs to no run, so its delivery identity is
/// the subject it speaks about plus its position in that subject's message — which makes a resend
/// idempotent exactly as a run's chunks are.
public struct LearningNoticeChunk: Sendable, Equatable {
  /// The polymorphic digest of whatever the notice addresses — a candidate, an evaluation, a
  /// promotion — matching the `subject_digest` the feedback tables key on.
  public let subjectDigest: String
  public let ordinal: Int
  public let chatID: Int64
  public let payload: String
  public let payloadHash: String
  public let replyMarkup: String?

  public init(
    subjectDigest: String,
    ordinal: Int,
    chatID: Int64,
    payload: String,
    payloadHash: String,
    replyMarkup: String? = nil
  ) {
    self.subjectDigest = subjectDigest
    self.ordinal = ordinal
    self.chatID = chatID
    self.payload = payload
    self.payloadHash = payloadHash
    self.replyMarkup = replyMarkup
  }
}

public struct OutboxRow: Sendable, Equatable {
  /// The row's identity, from the table's existing unique `dedup_key`. A learning notice has no
  /// run, so the run cannot be the identity; it stays as provenance.
  public let deliveryKey: String
  public let runID: Int64?
  public let stepIndex: Int
  public let chatID: Int64
  public let payload: String
  public let approvalID: Int64?
  public let replyMarkup: String?
  /// Stamped at enqueue from the run itself, so a row delivers into the topic that asked even
  /// after a restart, when no router is left to say where the answer belongs. Both nil in a DM.
  public let messageThreadID: Int64?
  public let replyToMessageID: Int64?

  /// Where this row goes, as the delivery seam takes it.
  public var target: DeliveryTarget {
    DeliveryTarget(
      chatID: chatID,
      messageThreadID: messageThreadID,
      replyToMessageID: replyToMessageID
    )
  }

  /// What a log line calls this row's origin: its run, or the learning source when it has none.
  public var originLabel: String { runID.map(String.init) ?? DeliverySource.learning.rawValue }

  public init(
    deliveryKey: String,
    runID: Int64?,
    stepIndex: Int,
    chatID: Int64,
    payload: String,
    approvalID: Int64? = nil,
    replyMarkup: String? = nil,
    messageThreadID: Int64? = nil,
    replyToMessageID: Int64? = nil
  ) {
    self.deliveryKey = deliveryKey
    self.runID = runID
    self.stepIndex = stepIndex
    self.chatID = chatID
    self.payload = payload
    self.approvalID = approvalID
    self.messageThreadID = messageThreadID
    self.replyToMessageID = replyToMessageID
    self.replyMarkup = replyMarkup
  }
}

public protocol OutboxStore: Sendable {
  func markSent(deliveryKey: String, telegramMessageID: Int64, now: Date) throws(StoreError)

  func pendingOutbound() throws(StoreError) -> [OutboxRow]
}
