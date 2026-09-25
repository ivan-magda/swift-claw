import ClawCore
import Foundation
import Logging
import ServiceLifecycle

/// A one-shot, coalescing wake-up signal between a turn commit (producer) and the dispatcher
/// (consumer). `poke()` requests a drain; `finish()` ends the stream so the dispatcher's loop exits.
///
/// Buffering is `.bufferingNewest(1)`: the element is valueless (just "there is work"), and each
/// `drainOnce()` drains *all* pending rows, so a burst of pokes during one drain only needs a single
/// follow-up — coalescing avoids redundant empty drains.
public struct OutboxSignal: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  var notifications: AsyncStream<Void> {
    stream
  }

  public init() {
    (stream, continuation) = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )
  }

  /// Requests one drain. Safe to call from any thread; coalesced against an in-flight drain.
  public func poke() {
    continuation.yield(())
  }

  /// Ends the stream so the dispatcher's `for await` loop completes (used on teardown/tests).
  public func finish() {
    continuation.finish()
  }
}

/// Drains `PENDING` `outbound_deliveries` rows and delivers each at-least-once, recording the
/// returned `telegram_message_id` on success. It drains once on boot — recovering rows a
/// prior run committed but never sent (a crash between commit and send) — then again on every poke
/// the `TurnRunner` fires after a commit. Delivery is `sendRichMessage` with a plain `sendMessage`
/// fallback on any rich-send error.
///
/// Telegram rate-limits per chat, so a 429 puts only that chat on hold: its rows wait out the
/// `retry_after` the API asked for while every other chat's rows keep draining.
public struct OutboxDispatcher<ClockType: Clock>: Service where ClockType.Duration == Duration {
  private let outbox: any OutboxStore
  private let delivery: any MessageDelivery
  private let signal: OutboxSignal
  private let logger: Logger
  private let holds: FloodControlHolds<ClockType>

  public init(
    outbox: any OutboxStore,
    delivery: any MessageDelivery,
    signal: OutboxSignal,
    logger: Logger,
    clock: ClockType
  ) {
    self.outbox = outbox
    self.delivery = delivery
    self.signal = signal
    self.logger = logger
    holds = FloodControlHolds(clock: clock, signal: signal)
  }

  public func run() async throws {
    logger.info("outbox dispatcher starting")
    await cancelWhenGracefulShutdown {
      // Boot recovery first, before serving pokes: deliver anything a prior run left PENDING.
      await drainOnce()
      for await _ in signal.notifications {
        await drainOnce()
      }
    }
    await holds.cancelAndAwait()
    logger.info("outbox dispatcher stopped")
  }

  // MARK: - Load-bearing

  /// Drains every PENDING row in the store's order — a run's rows first, then any runless learning
  /// notice — delivering each and recording its `telegram_message_id` via `markSent`.
  /// **Non-throwing by contract** — the dispatcher must survive every store/transport failure
  /// rather than crash and strand the remaining rows.
  func drainOnce() async {
    let pendingRows: [OutboxRow]
    do {
      pendingRows = try outbox.pendingOutbound()
    } catch {
      logger.error("outbox drain aborted; could not read pending rows: \(error)")
      return
    }

    for row in pendingRows {
      if Task.isCancelled {
        break
      }

      if await holds.isHeld(row.chatID) {
        continue
      }

      let messageID: Int64
      do {
        messageID = try await send(row)
      } catch {
        if Task.isCancelled {
          break
        }

        if let retryAfter = Self.floodControlRetryAfter(error) {
          await hold(chat: row.chatID, forSeconds: retryAfter)
          continue
        }

        logger.warning(
          """
          outbox send failed for \(row.originLabel) step \(row.stepIndex); \
          leaving it and later rows for the next drain: \(error)
          """
        )
        break
      }

      do {
        try outbox.markSent(deliveryKey: row.deliveryKey, telegramMessageID: messageID, now: Date())
        logger.debug(
          "outbox delivered \(row.originLabel) step \(row.stepIndex) as message \(messageID)"
        )
      } catch {
        logger.error(
          """
          outbox delivered \(row.originLabel) step \(row.stepIndex) (message \(messageID)) \
          but recording it failed; expect a duplicate: \(error)
          """
        )
      }
    }
  }

  /// Delivers one row, returning the Telegram `message_id` so the caller can record it via `markSent`.
  ///
  /// Sends the payload as rich markdown; on a rich-send error it re-sends the same payload as
  /// plain `sendMessage` so a malformed-markdown reply still lands. Flood control is the exception:
  /// a 429 answers the request rather than its formatting, so retrying it as plain text would spend
  /// a second call against the very limit that just fired.
  /// `replyMarkup` (the inline keyboard) rides both the rich send and the plain fallback, so a
  /// degraded delivery never drops the approval keyboard. A failure of the plain fallback itself
  /// propagates — the row stays PENDING for the next drain.
  private func send(_ row: OutboxRow) async throws -> Int64 {
    do {
      return try await delivery.sendRichMessage(
        to: row.target,
        markdown: row.payload,
        replyMarkup: row.replyMarkup
      )
    } catch {
      if Self.floodControlRetryAfter(error) != nil {
        throw error
      }

      logger.warning(
        """
        rich send failed for \(row.originLabel) step \(row.stepIndex), \
        falling back to plain: \(error)
        """
      )

      return try await delivery.sendMessage(
        to: row.target,
        text: row.payload,
        replyMarkup: row.replyMarkup
      )
    }
  }
}

// MARK: - Flood Control

private extension OutboxDispatcher {
  /// Parks one chat for the `retry_after` Telegram asked for and arranges the drain that resumes it:
  /// the producer only pokes on a fresh commit, so without this wake-up a held chat would wait for
  /// unrelated traffic before its rows moved.
  func hold(chat chatID: Int64, forSeconds retryAfter: Int) async {
    await holds.hold(chatID, for: .seconds(retryAfter))
    logger.warning("flood control on chat \(chatID); holding its rows for \(retryAfter)s")
  }

  static func floodControlRetryAfter(_ error: any Error) -> Int? {
    guard case .some(.floodControl(let retryAfter)) = error as? TelegramError else {
      return nil
    }
    return retryAfter
  }
}

/// Keeps each chat's retry deadline across drains and owns the wakeups until service shutdown.
private actor FloodControlHolds<ClockType: Clock> where ClockType.Duration == Duration {
  private let clock: ClockType
  private let signal: OutboxSignal
  private var notBefore: [Int64: ClockType.Instant] = [:]
  private var wakeups: [UUID: Task<Void, Never>] = [:]
  private var stopping = false

  init(clock: ClockType, signal: OutboxSignal) {
    self.clock = clock
    self.signal = signal
  }

  /// Whether `chatID` is still inside a hold; an elapsed hold is dropped on the way out so the map
  /// stays the size of the currently-throttled chats.
  func isHeld(_ chatID: Int64) -> Bool {
    guard let deadline = notBefore[chatID] else {
      return false
    }

    if clock.now < deadline {
      return true
    }
    notBefore[chatID] = nil

    return false
  }

  /// Extends the chat's hold, never shortens it: two 429s in one drain leave the later deadline.
  func hold(_ chatID: Int64, for wait: Duration) {
    guard !stopping else {
      return
    }

    let deadline = clock.now.advanced(by: wait)
    notBefore[chatID] = max(notBefore[chatID] ?? deadline, deadline)

    let id = UUID()
    wakeups[id] = Task {
      defer { wakeups[id] = nil }

      do {
        try await clock.sleep(until: deadline, tolerance: nil)
        try Task.checkCancellation()
        signal.poke()
      } catch {
        return
      }
    }
  }

  func cancelAndAwait() async {
    stopping = true

    let owned = Array(wakeups.values)
    for wakeup in owned {
      wakeup.cancel()
    }

    for wakeup in owned {
      await wakeup.value
    }
  }
}

// MARK: - Production Clock

extension OutboxDispatcher where ClockType == ContinuousClock {
  public init(
    outbox: any OutboxStore,
    delivery: any MessageDelivery,
    signal: OutboxSignal,
    logger: Logger
  ) {
    self.init(
      outbox: outbox,
      delivery: delivery,
      signal: signal,
      logger: logger,
      clock: ContinuousClock()
    )
  }
}
