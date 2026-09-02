import ClawCore
import Foundation
import Logging
import ServiceLifecycle
import Synchronization

/// A one-shot, coalescing wake-up signal between a turn commit (producer) and the dispatcher
/// (consumer). `poke()` requests a drain; `finish()` ends the stream so the dispatcher's loop exits.
///
/// Buffering is `.bufferingNewest(1)`: the element is valueless (just "there is work"), and each
/// `drainOnce()` drains *all* pending rows, so a burst of pokes during one drain only needs a single
/// follow-up — coalescing avoids redundant empty drains.
public struct OutboxSignal: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  var notifications: AsyncStream<Void> { stream }

  public init() {
    (stream, continuation) = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )
  }

  /// Requests one drain. Safe to call from any thread; coalesced against an in-flight drain.
  public func poke() { continuation.yield(()) }

  /// Ends the stream so the dispatcher's `for await` loop completes (used on teardown/tests).
  public func finish() { continuation.finish() }
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
  private let clock: ClockType
  private let holds: FloodControlHolds<ClockType.Instant>

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
    self.clock = clock
    holds = FloodControlHolds()
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
      // Stop promptly on graceful shutdown: leave the rest PENDING for boot recovery rather
      // than starting new sends while the task is unwinding.
      if Task.isCancelled { break }

      // A chat Telegram is throttling waits out its hold; the rows of every other chat carry on.
      // Order inside a run survives because a run answers exactly one chat.
      if holds.isHeld(row.chatId, now: clock.now) { continue }

      let messageId: Int64
      do {
        messageId = try await send(row)
      } catch {
        // A send interrupted by shutdown is not a fault — the row stays PENDING and boot recovery
        // redelivers it; only a genuine failure is worth a warning.
        if Task.isCancelled { break }
        if let retryAfter = Self.floodControlRetryAfter(error) {
          hold(chat: row.chatId, forSeconds: retryAfter)
          continue
        }
        // Recoverable: leave this row and any later ones PENDING and stop, so a multi-chunk reply
        // redelivers in order on the next drain rather than racing later chunks ahead of this one.
        // A row that *permanently* fails to send therefore stalls itself and every later row on
        // every drain — there is no hot-retry, attempt cap, or dead-letter path yet. Rate limiting
        // is the one failure that does not stall the drain, because it is the one failure Telegram
        // tells us how long to wait out.
        logger.warning(
          "outbox send failed for \(row.originLabel) step \(row.stepIndex); leaving it and later rows for the next drain: \(error)"
        )
        break
      }

      do {
        try outbox.markSent(
          deliveryKey: row.deliveryKey,
          telegramMessageId: messageId,
          now: Date()
        )
        logger.debug(
          "outbox delivered \(row.originLabel) step \(row.stepIndex) as message \(messageId)"
        )
      } catch {
        // The send already went out; we just couldn't record it, so the row stays PENDING and
        // re-sends next drain — an accepted at-least-once duplicate.
        logger.error(
          "outbox delivered \(row.originLabel) step \(row.stepIndex) (message \(messageId)) but recording it failed; expect a duplicate: \(error)"
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
      if Self.floodControlRetryAfter(error) != nil { throw error }
      logger.warning(
        "rich send failed for \(row.originLabel) step \(row.stepIndex), falling back to plain: \(error)"
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
  func hold(chat chatId: Int64, forSeconds retryAfter: Int) {
    let wait = Duration.seconds(retryAfter)
    holds.hold(chatId, until: clock.now.advanced(by: wait))
    logger.warning("flood control on chat \(chatId); holding its rows for \(retryAfter)s")
    Task { [signal, clock] in
      try? await clock.sleep(for: wait)
      signal.poke()
    }
  }

  static func floodControlRetryAfter(_ error: any Error) -> Int? {
    guard case .some(.floodControl(let retryAfter)) = error as? TelegramError else {
      return nil
    }
    return retryAfter
  }
}

/// The instants before which each throttled chat must not be sent to. Reference-typed so a hold
/// outlives the drain that recorded it — a hold living only for one drain would let the next poke
/// walk straight back into the same rate limit.
private final class FloodControlHolds<Instant: InstantProtocol>: Sendable {
  private let notBefore = Mutex<[Int64: Instant]>([:])

  /// Whether `chatId` is still inside a hold; an elapsed hold is dropped on the way out so the map
  /// stays the size of the currently-throttled chats.
  func isHeld(_ chatId: Int64, now: Instant) -> Bool {
    notBefore.withLock { held in
      guard let deadline = held[chatId] else {
        return false
      }
      if now < deadline { return true }
      held[chatId] = nil
      return false
    }
  }

  /// Extends the chat's hold, never shortens it: two 429s in one drain leave the later deadline.
  func hold(_ chatId: Int64, until deadline: Instant) {
    notBefore.withLock { held in
      held[chatId] = max(held[chatId] ?? deadline, deadline)
    }
  }
}

// MARK: - Production Clock

public extension OutboxDispatcher where ClockType == ContinuousClock {
  init(
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
