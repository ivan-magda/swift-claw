import ClawCore
import Foundation

/// Best-effort ephemeral draft sink: caps markdown at the rich-message limit and swallows every
/// transport error (the draft is cosmetic UX, like the typing action). Flood control is the
/// exception: it holds that chat's drafts for the `retry_after` Telegram named, because the caller
/// offers a fresh frame on every probe and would otherwise keep hitting a throttled chat. Per-send
/// time bounding lives in the caller — `StreamingTurnRuntime` abandons a send at its deadline — so
/// a stalled POST needs no escape hatch here.
public struct TelegramRichDraftStreamer<ClockType: Clock>: RichDraftStreaming
where ClockType.Duration == Duration {
  private let transport: any TelegramTransport
  private let holds: DraftFloodControlHolds<ClockType>

  public init(transport: any TelegramTransport, clock: ClockType) {
    self.transport = transport
    self.holds = DraftFloodControlHolds(clock: clock)
  }

  /// Telegram accepts a draft only in a private chat, so the negative chat id of every group is
  /// refused here and reported as undelivered — a group turn keeps the typing action as its only
  /// progress signal rather than falling silent behind a bubble that never appears. A held chat is
  /// reported as undelivered the same way, without a request.
  public func sendDraft(chatID: Int64, draftID: Int64, markdown: String) async -> Bool {
    guard chatID > 0, await !holds.isHeld(chatID) else {
      return false
    }

    let capped = String(markdown.prefix(TelegramMessageLimits.maxRichMessageCharacters))
    do {
      return try await transport.sendRichMessageDraft(
        chatID: chatID,
        draftID: draftID,
        markdown: capped
      )
    } catch TelegramError.floodControl(let retryAfter) {
      await holds.hold(chatID, for: .seconds(retryAfter))
      return false
    } catch {
      return false
    }
  }
}

extension TelegramRichDraftStreamer where ClockType == ContinuousClock {
  public init(transport: any TelegramTransport) {
    self.init(transport: transport, clock: ContinuousClock())
  }
}

// MARK: - Flood Control

/// Keeps each chat's draft hold for as long as the streamer lives, so a chat throttled in one turn
/// stays held into the next.
private actor DraftFloodControlHolds<ClockType: Clock> where ClockType.Duration == Duration {
  private let clock: ClockType
  private var deadlines = FloodControlDeadlines<ClockType.Instant>()

  init(clock: ClockType) {
    self.clock = clock
  }

  func isHeld(_ chatID: Int64) -> Bool {
    deadlines.isHeld(chatID, at: clock.now)
  }

  func hold(_ chatID: Int64, for wait: Duration) {
    deadlines.hold(chatID, until: clock.now.advanced(by: wait))
  }
}
