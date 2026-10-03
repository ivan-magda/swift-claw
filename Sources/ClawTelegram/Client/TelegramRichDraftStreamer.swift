import ClawCore
import Foundation

/// Best-effort ephemeral draft sink: caps markdown at the rich-message limit and swallows every
/// transport error (the draft is cosmetic UX, like the typing action). A rejected action emoji
/// gets one ordinary-emoji retry. Flood control holds that chat's drafts for `retry_after`, because the caller
/// offers a fresh frame on every probe and would otherwise keep hitting a throttled chat. Per-send
/// time bounding lives in the caller — `StreamingTurnRuntime` abandons a send at its deadline — so
/// a stalled POST needs no escape hatch here.
public struct TelegramRichDraftStreamer<ClockType: Clock>: RichDraftStreaming
where ClockType.Duration == Duration {
  private let transport: any TelegramTransport
  private let deliveryState: DraftDeliveryState<ClockType>

  public init(transport: any TelegramTransport, clock: ClockType) {
    self.transport = transport
    self.deliveryState = DraftDeliveryState(clock: clock)
  }

  /// Telegram accepts a draft only in a private chat, so the negative chat id of every group is
  /// refused here and reported as undelivered — a group turn keeps the typing action as its only
  /// progress signal rather than falling silent behind a bubble that never appears. A held chat is
  /// reported as undelivered the same way, without a request.
  public func sendDraft(chatID: Int64, draftID: Int64, markdown: String) async -> Bool {
    await sendDraft(
      chatID: chatID,
      draftID: draftID,
      draft: RichDraft(markdown: markdown),
      stopControl: .unavailable
    )
  }

  public func sendDraft(
    chatID: Int64,
    draftID: Int64,
    draft: RichDraft,
    stopControl: DraftStopControl
  ) async -> Bool {
    guard chatID > 0 else {
      return false
    }

    let isHeld = await deliveryState.isHeld(chatID)
    guard !isHeld else {
      return false
    }

    let cappedMarkdown = String(
      draft.markdown.prefix(TelegramMessageLimits.maxRichMessageCharacters)
    )
    let fallbackMarkdown = draft.fallbackMarkdown.map {
      String($0.prefix(TelegramMessageLimits.maxRichMessageCharacters))
    }
    let usesFallbackEmoji = await deliveryState.usesFallbackEmoji
    let candidateMarkdown = usesFallbackEmoji ? fallbackMarkdown ?? cappedMarkdown : cappedMarkdown

    do {
      do {
        return try await transport.sendRichMessageDraft(
          chatID: chatID,
          draftID: draftID,
          markdown: candidateMarkdown,
          stopControl: stopControl
        )
      } catch TelegramError.apiError(let code, let description) where code == 400 {
        guard let fallbackMarkdown, candidateMarkdown != fallbackMarkdown else {
          throw TelegramError.apiError(code: code, description: description)
        }

        try Task.checkCancellation()

        let fallbackDelivered = try await transport.sendRichMessageDraft(
          chatID: chatID,
          draftID: draftID,
          markdown: fallbackMarkdown,
          stopControl: stopControl
        )
        if fallbackDelivered {
          await deliveryState.preferFallbackEmoji()
        }

        return fallbackDelivered
      }
    } catch TelegramError.floodControl(let retryAfter) {
      await deliveryState.hold(chatID, for: .seconds(retryAfter))
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

// MARK: - Delivery Compatibility and Flood Control

/// Keeps each chat's draft hold for as long as the streamer lives, so a chat throttled in one turn
/// stays held into the next.
private actor DraftDeliveryState<ClockType: Clock> where ClockType.Duration == Duration {
  private let clock: ClockType
  private var deadlines = FloodControlDeadlines<ClockType.Instant>()
  private(set) var usesFallbackEmoji = false

  init(clock: ClockType) {
    self.clock = clock
  }

  func isHeld(_ chatID: Int64) -> Bool {
    deadlines.isHeld(chatID, at: clock.now)
  }

  func hold(_ chatID: Int64, for wait: Duration) {
    deadlines.hold(chatID, until: clock.now.advanced(by: wait))
  }

  /// Retain a working representation after an ordinary-emoji retry succeeds.
  func preferFallbackEmoji() {
    usesFallbackEmoji = true
  }
}
