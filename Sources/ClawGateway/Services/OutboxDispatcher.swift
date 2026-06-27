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
/// returned `telegram_message_id` on success (§6.4). It drains once on boot — recovering rows a
/// prior run committed but never sent (a crash between commit and send) — then again on every poke
/// the `TurnRunner` fires after a commit. Delivery is `sendRichMessage` with a plain `sendMessage`
/// fallback on any rich-send error (§6.4 / F8).
public struct OutboxDispatcher: Service {
  private let outbox: any OutboxStore
  private let transport: any TelegramTransport
  private let signal: OutboxSignal
  private let logger: Logger

  public init(
    outbox: any OutboxStore,
    transport: any TelegramTransport,
    signal: OutboxSignal,
    logger: Logger
  ) {
    self.outbox = outbox
    self.transport = transport
    self.signal = signal
    self.logger = logger
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

  /// Drains every PENDING row in `(run_id, step_index)` order, delivering each and recording its
  /// `telegram_message_id` via `markSent`. **Non-throwing by contract** — the dispatcher must
  /// survive every store/transport failure rather than crash and strand the remaining rows.
  func drainOnce() async {
    let pendingRows: [OutboxRow]
    do {
      pendingRows = try outbox.pendingOutbound()
    } catch {
      logger.error("outbox drain aborted; could not read pending rows: \(error)")
      return
    }

    for row in pendingRows {
      // Stop promptly on graceful shutdown: leave the rest PENDING for boot recovery (F22) rather
      // than starting new sends while the task is unwinding.
      if Task.isCancelled { break }

      let messageId: Int64
      do {
        messageId = try await send(row)
      } catch {
        // A send interrupted by shutdown is not a fault — the row stays PENDING and boot recovery
        // redelivers it; only a genuine failure is worth a warning.
        if Task.isCancelled { break }
        // Recoverable: leave this row and any later ones PENDING and stop, so a multi-chunk reply
        // redelivers in order on the next drain rather than racing later chunks ahead of this one.
        // A row that *permanently* fails to send therefore stalls itself and every later row on
        // every drain — there is no hot-retry and no attempt cap in Inc 1; a dead-letter path is a
        // later increment. Tolerable here because the only recipient is the owner's own DM.
        logger.warning(
          "outbox send failed for run \(row.runId) step \(row.stepIndex); leaving it and later rows for the next drain: \(error)"
        )
        break
      }

      do {
        try outbox.markSent(
          runId: row.runId,
          stepIndex: row.stepIndex,
          telegramMessageId: messageId,
          now: Date()
        )
        logger.debug(
          "outbox delivered run \(row.runId) step \(row.stepIndex) as message \(messageId)"
        )
      } catch {
        // The send already went out; we just couldn't record it, so the row stays PENDING and
        // re-sends next drain — an accepted at-least-once duplicate.
        logger.error(
          "outbox delivered run \(row.runId) step \(row.stepIndex) (message \(messageId)) but recording it failed; expect a duplicate: \(error)"
        )
      }
    }
  }

  /// Delivers one row, returning the Telegram `message_id` so the caller can record it via `markSent`.
  ///
  /// Sends the payload as rich markdown; on **any** rich-send error it re-sends the same payload as
  /// plain `sendMessage` so a malformed-markdown reply still lands (F8, "no formatting errors"). A
  /// failure of the plain fallback itself propagates — the row stays PENDING for the next drain.
  private func send(_ row: OutboxRow) async throws -> Int64 {
    do {
      return try await transport.sendRichMessage(chatId: row.chatId, markdown: row.payload)
    } catch {
      logger.warning(
        "rich send failed for run \(row.runId) step \(row.stepIndex), falling back to plain: \(error)"
      )
      return try await transport.sendMessage(chatId: row.chatId, text: row.payload)
    }
  }
}
