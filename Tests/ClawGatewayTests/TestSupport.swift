import ClawCore
import ClawData
import Foundation
import GRDB
import Testing

@testable import ClawGateway

/// Records the turns the router dispatches (and optionally throws a scripted error) so router/poller
/// tests stay decoupled from the real provider/persistence.
actor FakeTurnRunner: TurnDispatching {
  struct Call: Sendable, Equatable {
    let runId: Int64
    let sessionId: Int64
    let chatId: Int64
    let triggerMessageId: Int64
  }

  private(set) var calls: [Call] = []
  private let error: (any Error)?
  private var continuations: [CheckedContinuation<Void, Never>] = []

  init(error: (any Error)? = nil) { self.error = error }

  func run(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64
  ) async throws {
    calls.append(
      Call(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        triggerMessageId: triggerMessageId
      )
    )
    for continuation in continuations {
      continuation.resume()
    }
    continuations.removeAll()
    if let error { throw error }
  }

  func waitForCalls(atLeast count: Int) async {
    while calls.count < count {
      await withCheckedContinuation { continuation in
        continuations.append(continuation)
      }
    }
  }
}

/// Records outbound sends and scripts getUpdates batches/errors for poller tests. Exposes
/// deterministic, continuation-based wait points (`waitForSends`/`waitForAttempts`/`waitForPolls`)
/// that resume exactly when an event lands — no polling or timeouts, so tests stay parallel-safe.
actor RecordingTransport: TelegramTransport {
  struct DraftRecord: Sendable, Equatable {
    let chatId: Int64
    let draftId: Int64
    let markdown: String
  }

  private(set) var sent: [(chatId: Int64, text: String)] = []
  private(set) var richSends: [(chatId: Int64, markdown: String)] = []
  private(set) var drafts: [DraftRecord] = []
  private(set) var sendAttempts = 0
  private(set) var pollCount = 0
  private var batches: [[RawUpdate]]
  private let onExhausted: TelegramError?
  private let sendError: TelegramError?
  private let richError: TelegramError?
  /// Fails the rich send whose `sendAttempts` index equals this, and poisons that row's plain
  /// fallback too — so the whole delivery fails, modeling a genuinely undeliverable row mid-batch.
  private let failSendAtAttempt: Int?
  private var failPlainFallbackNext = false

  private enum Event { case sent, attempt, poll, draft }

  private var waiters: [Event: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)]] =
    [:]

  init(
    batches: [[RawUpdate]] = [],
    throwAfterExhaustion: TelegramError? = nil,
    sendError: TelegramError? = nil,
    richError: TelegramError? = nil,
    failSendAtAttempt: Int? = nil
  ) {
    self.batches = batches
    self.onExhausted = throwAfterExhaustion
    self.sendError = sendError
    self.richError = richError
    self.failSendAtAttempt = failSendAtAttempt
  }

  func getMe() async throws -> BotIdentity { BotIdentity(id: 1, username: "claw_bot") }

  func getUpdates(
    offset: Int64?,
    timeout: Int,
    allowedUpdates: [String]
  ) async throws -> [RawUpdate] {
    pollCount += 1
    resumeWaiters(.poll, reached: pollCount)
    if batches.isEmpty {
      if let onExhausted {
        throw onExhausted
      }
      try? await Task.sleep(for: .milliseconds(5))  // emulate an idle long-poll, not a tight spin
      return []
    }
    return batches.removeFirst()
  }

  func sendMessage(chatId: Int64, text: String) async throws -> Int64 {
    sendAttempts += 1
    resumeWaiters(.attempt, reached: sendAttempts)
    if let sendError {
      throw sendError  // simulate a transient send failure (direct canned reply, or rich fallback)
    }
    if failPlainFallbackNext {
      failPlainFallbackNext = false
      throw TelegramError.transport("plain fallback down")  // this row is undeliverable mid-batch
    }
    sent.append((chatId, text))
    resumeWaiters(.sent, reached: sent.count + richSends.count)
    return Int64(sendAttempts)
  }

  func sendRichMessage(chatId: Int64, markdown: String) async throws -> Int64 {
    sendAttempts += 1
    resumeWaiters(.attempt, reached: sendAttempts)
    if let richError {
      throw richError  // simulate a rich-send failure so the dispatcher falls back to plain
    }
    if sendAttempts == failSendAtAttempt {
      failPlainFallbackNext = true  // the dispatcher's plain retry for THIS row must also fail
      throw TelegramError.transport("rich down")
    }
    richSends.append((chatId, markdown))
    resumeWaiters(.sent, reached: sent.count + richSends.count)
    return Int64(sendAttempts)
  }

  func sendRichMessageDraft(chatId: Int64, draftId: Int64, markdown: String) async throws -> Bool {
    drafts.append(DraftRecord(chatId: chatId, draftId: draftId, markdown: markdown))
    resumeWaiters(.draft, reached: drafts.count)
    return true
  }

  func sendChatAction(chatId: Int64, action: String) async throws {}

  /// Suspends until at least `threshold` messages have been recorded as sent.
  func waitForSends(atLeast threshold: Int) async {
    await wait(.sent, current: sent.count, threshold: threshold)
  }

  /// Suspends until at least `threshold` send attempts (successful or failed) have been made.
  func waitForAttempts(atLeast threshold: Int) async {
    await wait(.attempt, current: sendAttempts, threshold: threshold)
  }

  /// Suspends until `getUpdates` has been called at least `threshold` times.
  func waitForPolls(atLeast threshold: Int) async {
    await wait(.poll, current: pollCount, threshold: threshold)
  }

  /// Suspends until at least `threshold` draft updates have been recorded.
  func waitForDrafts(atLeast threshold: Int) async {
    await wait(.draft, current: drafts.count, threshold: threshold)
  }

  private func wait(_ event: Event, current: Int, threshold: Int) async {
    guard current < threshold else { return }
    await withCheckedContinuation { continuation in
      waiters[event, default: []].append((threshold, continuation))
    }
  }

  private func resumeWaiters(_ event: Event, reached current: Int) {
    guard let pending = waiters[event] else { return }
    waiters[event] = pending.filter { $0.threshold > current }
    for waiter in pending where waiter.threshold <= current {
      waiter.continuation.resume()
    }
  }
}

func textUpdate(id: Int64, from: Int64, chat: Int64? = nil, text: String) -> RawUpdate {
  RawUpdate(
    updateId: id,
    message: RawMessage(
      messageId: id,
      fromUserId: from,
      chatId: chat ?? from,
      text: text,
      caption: nil,
      mediaKind: nil
    ),
    editedMessage: nil
  )
}

/// A seeded in-memory database: a session, an inbound message, and a RUNNING run with no outbox row.
/// The outbox and runs stores share the same writer, so a row claimed through one is visible to the
/// other. The RUNNING-with-no-outbox shape doubles as the crash-mid-turn state boot-reconcile tests
/// need.
struct SeededFixture {
  let outbox: OutboxStoreGRDB
  let runs: RunStoreGRDB
  let runId: Int64
  let chatId: Int64
}

/// Seeds the durable spine so that the `outbound_deliveries.run_id` FK is satisfied — ready for
/// callers to claim outbound rows or run a boot-reconcile sweep against a RUNNING run.
func makeSeededFixture() throws -> SeededFixture {
  let queue = try ClawDatabase.makeInMemoryQueue()
  try ClawDatabase.migrate(queue)

  let chatId: Int64 = 42
  let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
    InboundMessage(
      updateId: 1,
      sessionKey: SessionKey.telegramDM(chatId: chatId),
      chatId: chatId,
      userId: chatId,
      text: "hi",
      isEdited: false,
      ts: Date()
    )
  )
  let runId = try #require(claim.runId)
  let runs = RunStoreGRDB(writer: queue)
  #expect(try runs.pickUp(runId: runId, now: Date()))
  return SeededFixture(
    outbox: OutboxStoreGRDB(writer: queue),
    runs: runs,
    runId: runId,
    chatId: chatId
  )
}
