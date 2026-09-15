import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

/// Counts calls into a `Sendable` value-type double, so a stub can behave differently on its first
/// call than on the redelivery that follows.
actor CallCounter {
  private(set) var count = 0

  func next() -> Int {
    count += 1
    return count
  }
}

/// Records the turns the router dispatches (and optionally throws a scripted error) so router/poller
/// tests stay decoupled from the real provider/persistence.
actor FakeTurnRunner: TurnDispatching {
  struct Call: Sendable, Equatable {
    let runID: Int64
    let sessionID: Int64
    let chatID: Int64
    let triggerMessageID: Int64
  }

  private(set) var calls: [Call] = []
  private let error: (any Error)?
  private var continuations: [CheckedContinuation<Void, Never>] = []

  init(error: (any Error)? = nil) { self.error = error }

  func run(runID: Int64, sessionID: Int64, chatID: Int64, triggerMessageID: Int64) async throws {
    calls.append(
      Call(runID: runID, sessionID: sessionID, chatID: chatID, triggerMessageID: triggerMessageID)
    )
    for continuation in continuations {
      continuation.resume()
    }
    continuations.removeAll()
    if let error {
      throw error
    }
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
    let chatID: Int64
    let draftID: Int64
    let markdown: String
  }

  struct CallbackAnswer: Sendable, Equatable {
    let id: String
    let text: String?
  }

  struct MarkupEdit: Sendable, Equatable {
    let chatID: Int64
    let messageID: Int64
    let replyMarkup: String?
  }

  private(set) var sent: [(target: DeliveryTarget, text: String)] = []
  private(set) var answeredCallbacks: [CallbackAnswer] = []
  private(set) var markupEdits: [MarkupEdit] = []
  private(set) var richSends: [(target: DeliveryTarget, markdown: String)] = []
  private(set) var drafts: [DraftRecord] = []
  private(set) var sendAttempts = 0
  private(set) var pollCount = 0
  private(set) var lastAllowedUpdates: [String] = []

  private var batches: [[RawUpdate]]
  private let onExhausted: TelegramError?
  private let sendError: TelegramError?
  private let richError: TelegramError?
  /// Fails the rich send whose `sendAttempts` index equals this, and poisons that row's plain
  /// fallback too — so the whole delivery fails, modeling a genuinely undeliverable row mid-batch.
  private let failSendAtAttempt: Int?

  private var failPlainFallbackNext = false

  private enum Event { case sent, attempt, poll, draft, answer }

  private var waiters: [Event: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)]] =
    [:]

  init(
    batches: [[RawUpdate]] = [],
    throwAfterExhaustion onExhausted: TelegramError? = nil,
    sendError: TelegramError? = nil,
    richError: TelegramError? = nil,
    failSendAtAttempt: Int? = nil
  ) {
    self.batches = batches
    self.onExhausted = onExhausted
    self.sendError = sendError
    self.richError = richError
    self.failSendAtAttempt = failSendAtAttempt
  }

  func getMe() async throws -> BotIdentity { BotIdentity(id: 1, username: "claw_bot") }

  func getUpdates(offset: Int64?, timeout: Int, allowedUpdates: [String]) async throws
    -> [RawUpdate]
  {
    pollCount += 1
    lastAllowedUpdates = allowedUpdates
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

  // Recorded sends don't render keyboards; prompt-row assertions are DB-side (outbox rows).
  func sendMessage(to target: DeliveryTarget, text: String, replyMarkup: String?) async throws
    -> Int64
  {
    sendAttempts += 1
    resumeWaiters(.attempt, reached: sendAttempts)
    if let sendError {
      throw sendError  // simulate a transient send failure (direct canned reply, or rich fallback)
    }
    if failPlainFallbackNext {
      failPlainFallbackNext = false
      throw TelegramError.transport("plain fallback down")  // this row is undeliverable mid-batch
    }
    sent.append((target, text))
    resumeWaiters(.sent, reached: sent.count + richSends.count)
    return Int64(sendAttempts)
  }

  func sendRichMessage(to target: DeliveryTarget, markdown: String, replyMarkup: String?)
    async throws -> Int64
  {
    sendAttempts += 1
    resumeWaiters(.attempt, reached: sendAttempts)
    if let richError {
      throw richError  // simulate a rich-send failure so the dispatcher falls back to plain
    }
    if sendAttempts == failSendAtAttempt {
      failPlainFallbackNext = true  // the dispatcher's plain retry for THIS row must also fail
      throw TelegramError.transport("rich down")
    }
    richSends.append((target, markdown))
    resumeWaiters(.sent, reached: sent.count + richSends.count)
    return Int64(sendAttempts)
  }

  func sendRichMessageDraft(chatID: Int64, draftID: Int64, markdown: String) async throws -> Bool {
    drafts.append(DraftRecord(chatID: chatID, draftID: draftID, markdown: markdown))
    resumeWaiters(.draft, reached: drafts.count)
    return true
  }

  func sendChatAction(chatID: Int64, messageThreadID: Int64?, action: String) async throws {}

  func answerCallbackQuery(id: String, text: String?) async throws {
    answeredCallbacks.append(CallbackAnswer(id: id, text: text))
    resumeWaiters(.answer, reached: answeredCallbacks.count)
  }

  func editMessageReplyMarkup(chatID: Int64, messageID: Int64, replyMarkup: String?) async throws {
    markupEdits.append(MarkupEdit(chatID: chatID, messageID: messageID, replyMarkup: replyMarkup))
  }

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

  /// Suspends until at least `threshold` callback answers have been recorded.
  func waitForAnswers(atLeast threshold: Int) async {
    await wait(.answer, current: answeredCallbacks.count, threshold: threshold)
  }

  private func wait(_ event: Event, current: Int, threshold: Int) async {
    guard current < threshold else {
      return
    }
    await withCheckedContinuation { continuation in
      waiters[event, default: []].append((threshold, continuation))
    }
  }

  private func resumeWaiters(_ event: Event, reached current: Int) {
    guard let pending = waiters[event] else {
      return
    }
    waiters[event] = pending.filter {
      $0.threshold > current
    }
    for waiter in pending where waiter.threshold <= current {
      waiter.continuation.resume()
    }
  }
}

func textUpdate(
  id: Int64,
  from: Int64,
  chat: Int64? = nil,
  text: String,
  chatKind: ChatKind = .private,
  chatTitle: String? = nil,
  messageThreadID: Int64? = nil,
  senderDisplayName: String? = nil
) -> RawUpdate {
  RawUpdate(
    updateID: id,
    message: RawMessage(
      messageID: id,
      fromUserID: from,
      chatID: chat ?? from,
      text: text,
      caption: nil,
      mediaKind: nil,
      chatKind: chatKind,
      chatTitle: chatTitle,
      messageThreadID: messageThreadID,
      senderDisplayName: senderDisplayName
    ),
    editedMessage: nil
  )
}

/// A seeded in-memory database: a session, an inbound message, and a RUNNING run with no outbox row.
/// The RUNNING-with-no-outbox shape also represents a crash midway through a turn.
struct SeededFixture {
  let writer: any DatabaseWriter
  let outbox: OutboxStoreGRDB
  let runs: RunStoreGRDB
  let runID: Int64
  let chatID: Int64
}

/// Seeds a RUNNING turn for reply commits or boot reconciliation.
func makeSeededFixture(
  chatID: Int64 = 42,
  sessionKey: String? = nil,
  telegramMessageID: Int64? = nil
) throws -> SeededFixture {
  let queue = try TestDatabase.make()

  let runID = try seedRun(
    in: queue,
    chatID: chatID,
    sessionKey: sessionKey,
    telegramMessageID: telegramMessageID
  )
  return SeededFixture(
    writer: queue,
    outbox: OutboxStoreGRDB(writer: queue),
    runs: RunStoreGRDB(writer: queue),
    runID: runID,
    chatID: chatID
  )
}

/// Seeds one more session + inbound message + RUNNING run into an already-migrated database, so a
/// fixture can hold the runs of several chats — the shape a drain across chats needs.
@discardableResult
func seedRun(
  in writer: any DatabaseWriter,
  chatID: Int64,
  updateID: Int64 = 1,
  sessionKey: String? = nil,
  telegramMessageID: Int64? = nil
) throws -> Int64 {
  let claim = try SessionMessageStoreGRDB(writer: writer).claimAndPersistInbound(
    InboundMessage(
      updateID: updateID,
      sessionKey: sessionKey ?? SessionKey.telegramDM(chatID: chatID),
      chatID: chatID,
      userID: chatID,
      text: "hi",
      isEdited: false,
      telegramMessageID: telegramMessageID,
      ts: Date()
    )
  )
  let runID = try #require(claim.runID)
  _ = try #require(try RunStoreGRDB(writer: writer).pickUp(runID: runID, now: Date()))
  return runID
}

/// A boot-reconcile fixture with two HEALTHY runs and no unfinished orphan: a terminal DONE run, and
/// a still-RUNNING run whose single outbox row was already delivered (SENT). Reconcile must leave the
/// terminal run untouched and enqueue NO degradation for the already-answered run.
struct HealthyRunsFixture {
  let runs: RunStoreGRDB
  let outbox: OutboxStoreGRDB
  let doneRunID: Int64
  let deliveredRunID: Int64
}

func makeHealthyRunsFixture() throws -> HealthyRunsFixture {
  let queue = try TestDatabase.make()

  let messages = SessionMessageStoreGRDB(writer: queue)
  let runs = RunStoreGRDB(writer: queue)
  let outbox = OutboxStoreGRDB(writer: queue)
  let seededAt = Date()

  // A completed, terminal run (PENDING → RUNNING → DONE). Terminal runs fall outside reconcile's
  // PENDING/RUNNING sweep, so they must survive it unchanged.
  let doneChatID: Int64 = 42
  let doneClaim = try messages.claimAndPersistInbound(
    InboundMessage(
      updateID: 1,
      sessionKey: SessionKey.telegramDM(chatID: doneChatID),
      chatID: doneChatID,
      userID: doneChatID,
      text: "first",
      isEdited: false,
      ts: seededAt
    )
  )
  let doneRunID = try #require(doneClaim.runID)
  let doneSessionID = try #require(doneClaim.sessionID)
  _ = try #require(try runs.pickUp(runID: doneRunID, now: seededAt))
  let committed = try runs.commitAssistantTurn(
    AssistantTurn(
      runID: doneRunID,
      sessionID: doneSessionID,
      chatID: doneChatID,
      content: "all done",
      usage: ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-done"),
        runID: doneRunID,
        sessionID: doneSessionID,
        model: "gpt-4o",
        promptTokens: 10,
        completionTokens: 5,
        costUSD: 0.001,
        costSource: .heuristic,
        isEstimated: false,
        ts: seededAt
      ),
      chunks: []
    ),
    now: seededAt
  )
  #expect(committed == .committed)

  // A still-RUNNING run whose one outbox row was already delivered (SENT) before the crash: the
  // owner already heard the answer, so reconcile must fail the orphan WITHOUT a degradation reply.
  let deliveredChatID: Int64 = 43
  let deliveredClaim = try messages.claimAndPersistInbound(
    InboundMessage(
      updateID: 2,
      sessionKey: SessionKey.telegramDM(chatID: deliveredChatID),
      chatID: deliveredChatID,
      userID: deliveredChatID,
      text: "second",
      isEdited: false,
      ts: seededAt
    )
  )
  let deliveredRunID = try #require(deliveredClaim.runID)
  _ = try #require(try runs.pickUp(runID: deliveredRunID, now: seededAt))
  try OutboxFixture.seedLegacyRunDelivery(
    in: queue,
    runID: deliveredRunID,
    chunk: OutboxChunk(
      stepIndex: 0,
      chatID: deliveredChatID,
      payload: "already delivered",
      payloadHash: "hash"
    )
  )
  let deliveredKey = try #require(try outbox.pendingOutbound().first).deliveryKey
  try outbox.markSent(deliveryKey: deliveredKey, telegramMessageID: 555, now: seededAt)

  return HealthyRunsFixture(
    runs: runs,
    outbox: outbox,
    doneRunID: doneRunID,
    deliveredRunID: deliveredRunID
  )
}

/// Scripted draft parser: returns results in order (last one sticks), records every owner text.
actor FakeDraftParser: ScheduleDraftParsing {
  private var results: [ScheduleDraftParseResult]
  private(set) var ownerTexts: [String] = []

  init(results: [ScheduleDraftParseResult]) { self.results = results }

  init(result: ScheduleDraftParseResult) { self.init(results: [result]) }

  func parse(ownerText: String, sessionID: Int64) async -> ScheduleDraftParseResult {
    ownerTexts.append(ownerText)
    guard results.isEmpty == false else {
      return .unparseable
    }
    return results.count == 1 ? results[0] : results.removeFirst()
  }
}

/// An inert schedule surface for router tests that never touch `/schedule` — real stores over
/// the harness's own writer, a parser that can only fail.
func makeIdleScheduleSurface(writer: any DatabaseWriter) -> ScheduleSurface {
  ScheduleSurface(
    parser: FakeDraftParser(result: .unparseable),
    validator: ScheduleDraftValidator(minIntervalMinutes: 5, defaultTimezone: .gmt),
    calculator: OccurrenceCalculator(),
    jobs: ScheduledJobStoreGRDB(writer: writer),
    commands: ScheduleCommandStoreGRDB(writer: writer)
  )
}
