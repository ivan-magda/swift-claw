import ClawCore
import Foundation

public struct TelegramRichDraftStreamer: RichDraftStreaming {
  public static let maxMarkdownCharacters = 32_768
  private static let sendDeadline: Duration = .seconds(3)

  private let transport: any TelegramTransport
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    transport: any TelegramTransport,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.transport = transport
    self.sleep = sleep
  }

  public func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async {
    guard chatId > 0 else {
      return
    }

    let capped = String(markdown.prefix(Self.maxMarkdownCharacters))

    // A task-group race can still await a non-cooperative child during teardown. Keep the helper
    // tasks unstructured so deadline return is bounded; the AHC-backed production transport
    // cooperates with cancellation, while a broken fake may finish later without blocking callers.
    let stream = AsyncStream<Void> { continuation in
      let sendTask = Task {
        _ = try? await transport.sendRichMessageDraft(
          chatId: chatId,
          draftId: draftId,
          markdown: capped
        )
        continuation.yield()
        continuation.finish()
      }
      let deadlineTask = Task {
        try? await sleep(Self.sendDeadline)
        continuation.yield()
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in
        sendTask.cancel()
        deadlineTask.cancel()
      }
    }

    for await _ in stream {
      break
    }
  }
}
