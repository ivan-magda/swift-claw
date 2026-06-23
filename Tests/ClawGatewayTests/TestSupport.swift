import ClawCore
import Foundation

@testable import ClawGateway

/// Records the turns the router dispatches (and optionally throws a scripted error) so router/poller
/// tests stay decoupled from the real provider/persistence.
actor FakeTurnRunner: TurnDispatching {
  private(set) var calls: [(sessionId: Int64, chatId: Int64)] = []
  private let error: (any Error)?

  init(error: (any Error)? = nil) { self.error = error }

  func run(sessionId: Int64, chatId: Int64) async throws {
    calls.append((sessionId, chatId))
    if let error { throw error }
  }
}

/// Records outbound sends and scripts getUpdates batches/errors for poller tests. Exposes
/// deterministic, continuation-based wait points (`waitForSends`/`waitForAttempts`/`waitForPolls`)
/// that resume exactly when an event lands — no polling or timeouts, so tests stay parallel-safe.
actor RecordingTransport: TelegramTransport {
  private(set) var sent: [(chatId: Int64, text: String)] = []
  private(set) var sendAttempts = 0
  private(set) var pollCount = 0
  private var batches: [[RawUpdate]]
  private let onExhausted: TelegramError?
  private let sendError: TelegramError?

  private enum Event { case sent, attempt, poll }

  private var waiters: [Event: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)]] =
    [:]

  init(
    batches: [[RawUpdate]] = [],
    throwAfterExhaustion: TelegramError? = nil,
    sendError: TelegramError? = nil
  ) {
    self.batches = batches
    self.onExhausted = throwAfterExhaustion
    self.sendError = sendError
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

  func sendMessage(chatId: Int64, text: String) async throws {
    sendAttempts += 1
    resumeWaiters(.attempt, reached: sendAttempts)
    if let sendError {
      throw sendError  // simulate a transient send failure
    }
    sent.append((chatId, text))
    resumeWaiters(.sent, reached: sent.count)
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
