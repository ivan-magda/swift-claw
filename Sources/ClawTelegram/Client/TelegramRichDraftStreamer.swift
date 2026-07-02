import ClawCore
import Foundation

/// Best-effort ephemeral draft sink: caps markdown at the rich-message limit and swallows every
/// transport error (the draft is cosmetic UX, like the typing action). Per-send time bounding
/// lives in the caller — `StreamingTurnRuntime` abandons a send at its deadline — so a stalled
/// POST needs no escape hatch here.
public struct TelegramRichDraftStreamer: RichDraftStreaming {
  public static let maxMarkdownCharacters = 32_768

  private let transport: any TelegramTransport

  public init(transport: any TelegramTransport) {
    self.transport = transport
  }

  public func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async {
    guard chatId > 0 else {
      return
    }

    let capped = String(markdown.prefix(Self.maxMarkdownCharacters))
    _ = try? await transport.sendRichMessageDraft(
      chatId: chatId,
      draftId: draftId,
      markdown: capped
    )
  }
}
