import ClawCore
import Foundation

/// Best-effort ephemeral draft sink: caps markdown at the rich-message limit and swallows every
/// transport error (the draft is cosmetic UX, like the typing action). Per-send time bounding
/// lives in the caller — `StreamingTurnRuntime` abandons a send at its deadline — so a stalled
/// POST needs no escape hatch here.
public struct TelegramRichDraftStreamer: RichDraftStreaming {
  public static let maxMarkdownCharacters = TelegramMessageLimits.maxRichMessageCharacters

  private let transport: any TelegramTransport

  public init(transport: any TelegramTransport) {
    self.transport = transport
  }

  /// Telegram accepts a draft only in a private chat, so the negative chat id of every group is
  /// refused here and reported as undelivered — a group turn keeps the typing action as its only
  /// progress signal rather than falling silent behind a bubble that never appears.
  public func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async -> Bool {
    guard chatId > 0 else {
      return false
    }

    let capped = String(markdown.prefix(Self.maxMarkdownCharacters))
    let sent = try? await transport.sendRichMessageDraft(
      chatId: chatId,
      draftId: draftId,
      markdown: capped
    )
    return sent ?? false
  }
}
