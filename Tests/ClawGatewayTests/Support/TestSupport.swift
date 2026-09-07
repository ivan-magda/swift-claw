import ClawCore
import ClawData
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

  struct CallbackAnswer: Sendable, Equatable {
    let id: String
    let text: String?
  }

  struct MarkupEdit: Sendable, Equatable {
    let chatId: Int64
    let messageId: Int64
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
  func sendMessage(
    to target: DeliveryTarget,
    text: String,
    replyMarkup: String?
  ) async throws -> Int64 {
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

  func sendRichMessage(
    to target: DeliveryTarget,
    markdown: String,
    replyMarkup: String?
  ) async throws -> Int64 {
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

  func sendRichMessageDraft(chatId: Int64, draftId: Int64, markdown: String) async throws -> Bool {
    drafts.append(DraftRecord(chatId: chatId, draftId: draftId, markdown: markdown))
    resumeWaiters(.draft, reached: drafts.count)
    return true
  }

  func sendChatAction(chatId: Int64, messageThreadId: Int64?, action: String) async throws {}

  func answerCallbackQuery(id: String, text: String?) async throws {
    answeredCallbacks.append(CallbackAnswer(id: id, text: text))
    resumeWaiters(.answer, reached: answeredCallbacks.count)
  }

  func editMessageReplyMarkup(chatId: Int64, messageId: Int64, replyMarkup: String?) async throws {
    markupEdits.append(MarkupEdit(chatId: chatId, messageId: messageId, replyMarkup: replyMarkup))
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
    waiters[event] = pending.filter { $0.threshold > current }
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
  messageThreadId: Int64? = nil,
  senderDisplayName: String? = nil
) -> RawUpdate {
  RawUpdate(
    updateId: id,
    message: RawMessage(
      messageId: id,
      fromUserId: from,
      chatId: chat ?? from,
      text: text,
      caption: nil,
      mediaKind: nil,
      chatKind: chatKind,
      chatTitle: chatTitle,
      messageThreadId: messageThreadId,
      senderDisplayName: senderDisplayName
    ),
    editedMessage: nil
  )
}

/// A seeded in-memory database: a session, an inbound message, and a RUNNING run with no outbox row.
/// The outbox and runs stores share the same writer, so a row claimed through one is visible to the
/// other. The RUNNING-with-no-outbox shape doubles as the crash-mid-turn state boot-reconcile tests
/// need.
struct SeededFixture {
  let writer: any DatabaseWriter
  let outbox: OutboxStoreGRDB
  let runs: RunStoreGRDB
  let runId: Int64
  let chatId: Int64
}

/// Seeds the durable spine so that the `outbound_deliveries.run_id` FK is satisfied — ready for
/// callers to claim outbound rows or run a boot-reconcile sweep against a RUNNING run.
func makeSeededFixture(
  chatId: Int64 = 42,
  sessionKey: String? = nil,
  telegramMessageId: Int64? = nil
) throws -> SeededFixture {
  let queue = try ClawDatabase.makeInMemoryQueue()
  try ClawDatabase.migrate(queue)

  let runId = try seedRun(
    in: queue,
    chatId: chatId,
    sessionKey: sessionKey,
    telegramMessageId: telegramMessageId
  )
  return SeededFixture(
    writer: queue,
    outbox: OutboxStoreGRDB(writer: queue),
    runs: RunStoreGRDB(writer: queue),
    runId: runId,
    chatId: chatId
  )
}

/// Seeds one more session + inbound message + RUNNING run into an already-migrated database, so a
/// fixture can hold the runs of several chats — the shape a drain across chats needs.
@discardableResult
func seedRun(
  in writer: any DatabaseWriter,
  chatId: Int64,
  updateId: Int64 = 1,
  sessionKey: String? = nil,
  telegramMessageId: Int64? = nil
) throws -> Int64 {
  let claim = try SessionMessageStoreGRDB(writer: writer).claimAndPersistInbound(
    InboundMessage(
      updateId: updateId,
      sessionKey: sessionKey ?? SessionKey.telegramDM(chatId: chatId),
      chatId: chatId,
      userId: chatId,
      text: "hi",
      isEdited: false,
      telegramMessageId: telegramMessageId,
      ts: Date()
    )
  )
  let runId = try #require(claim.runId)
  _ = try #require(try RunStoreGRDB(writer: writer).pickUp(runId: runId, now: Date()))
  return runId
}

/// A boot-reconcile fixture with two HEALTHY runs and no unfinished orphan: a terminal DONE run, and
/// a still-RUNNING run whose single outbox row was already delivered (SENT). Reconcile must leave the
/// terminal run untouched and enqueue NO degradation for the already-answered run.
struct HealthyRunsFixture {
  let runs: RunStoreGRDB
  let outbox: OutboxStoreGRDB
  let doneRunId: Int64
  let deliveredRunId: Int64
}

func makeHealthyRunsFixture() throws -> HealthyRunsFixture {
  let queue = try ClawDatabase.makeInMemoryQueue()
  try ClawDatabase.migrate(queue)

  let messages = SessionMessageStoreGRDB(writer: queue)
  let runs = RunStoreGRDB(writer: queue)
  let outbox = OutboxStoreGRDB(writer: queue)
  let seededAt = Date()

  // A completed, terminal run (PENDING → RUNNING → DONE). Terminal runs fall outside reconcile's
  // PENDING/RUNNING sweep, so they must survive it unchanged.
  let doneChatId: Int64 = 42
  let doneClaim = try messages.claimAndPersistInbound(
    InboundMessage(
      updateId: 1,
      sessionKey: SessionKey.telegramDM(chatId: doneChatId),
      chatId: doneChatId,
      userId: doneChatId,
      text: "first",
      isEdited: false,
      ts: seededAt
    )
  )
  let doneRunId = try #require(doneClaim.runId)
  let doneSessionId = try #require(doneClaim.sessionId)
  _ = try #require(try runs.pickUp(runId: doneRunId, now: seededAt))
  let committed = try runs.commitAssistantTurn(
    AssistantTurn(
      runId: doneRunId,
      sessionId: doneSessionId,
      chatId: doneChatId,
      content: "all done",
      usage: ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-done"),
        runId: doneRunId,
        sessionId: doneSessionId,
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
  let deliveredChatId: Int64 = 43
  let deliveredClaim = try messages.claimAndPersistInbound(
    InboundMessage(
      updateId: 2,
      sessionKey: SessionKey.telegramDM(chatId: deliveredChatId),
      chatId: deliveredChatId,
      userId: deliveredChatId,
      text: "second",
      isEdited: false,
      ts: seededAt
    )
  )
  let deliveredRunId = try #require(deliveredClaim.runId)
  _ = try #require(try runs.pickUp(runId: deliveredRunId, now: seededAt))
  _ = try outbox.claimOutbound(
    runId: deliveredRunId,
    chunk: OutboxChunk(
      stepIndex: 0,
      chatId: deliveredChatId,
      payload: "already delivered",
      payloadHash: "hash"
    )
  )
  let deliveredKey = try #require(try outbox.pendingOutbound().first).deliveryKey
  try outbox.markSent(deliveryKey: deliveredKey, telegramMessageId: 555, now: seededAt)

  return HealthyRunsFixture(
    runs: runs,
    outbox: outbox,
    doneRunId: doneRunId,
    deliveredRunId: deliveredRunId
  )
}

/// Scripted draft parser: returns results in order (last one sticks), records every owner text.
actor FakeDraftParser: ScheduleDraftParsing {
  private var results: [ScheduleDraftParseResult]
  private(set) var ownerTexts: [String] = []

  init(results: [ScheduleDraftParseResult]) {
    self.results = results
  }

  init(result: ScheduleDraftParseResult) {
    self.init(results: [result])
  }

  func parse(ownerText: String, sessionId: Int64) async -> ScheduleDraftParseResult {
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
