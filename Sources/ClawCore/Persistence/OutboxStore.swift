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

public struct OutboxRow: Sendable, Equatable {
  /// The row's identity, from the table's existing unique `dedup_key`. A learning notice has no
  /// run, so the run cannot be the identity; it stays as provenance.
  public let deliveryKey: String
  public let runId: Int64?
  public let stepIndex: Int
  public let chatId: Int64
  public let payload: String
  public let approvalId: Int64?
  public let replyMarkup: String?
  /// Stamped at enqueue from the run itself, so a row delivers into the topic that asked even
  /// after a restart, when no router is left to say where the answer belongs. Both nil in a DM.
  public let messageThreadId: Int64?
  public let replyToMessageId: Int64?

  /// Where this row goes, as the delivery seam takes it.
  public var target: DeliveryTarget {
    DeliveryTarget(
      chatId: chatId,
      messageThreadId: messageThreadId,
      replyToMessageId: replyToMessageId
    )
  }

  /// What a log line calls this row's origin: its run, or the learning source when it has none.
  public var originLabel: String {
    runId.map(String.init) ?? DeliverySource.learning.rawValue
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
  /// Enqueues one chunk of an owner-facing learning notice, which belongs to no run. Idempotent on
  /// the chunk's own delivery key, so a retried enqueue never duplicates the message.
  func claimNotice(_ chunk: LearningNoticeChunk) throws(StoreError) -> Bool
  func markSent(deliveryKey: String, telegramMessageId: Int64, now: Date) throws(StoreError)
  func pendingOutbound() throws(StoreError) -> [OutboxRow]
}
