import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite struct TurnRunnerImageAttachTests {
  private let alpha = ImagePart(
    data: Data([0xFF, 0xD8, 0xFF, 0xE0]),
    mediaType: .jpeg,
    width: 640,
    height: 480
  )
  private let beta = ImagePart(
    data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    mediaType: .png,
    width: 320,
    height: 240
  )

  @Test func eachImageStaysOnItsOwnMessageThroughTheRowsSanitizingDrops() throws {
    // given — a leading orphaned tool row, which sanitizing drops and every later position shifts by
    let snapshot = SessionContextSnapshot(
      history: [
        StoredMessage(role: .tool, content: "orphan", provenance: .untrusted, toolCallId: "gone"),
        StoredMessage(role: .user, content: "first caption", provenance: .untrusted),
        StoredMessage(role: .assistant, content: "an answer", provenance: .trusted),
        StoredMessage(role: .user, content: "second caption", provenance: .untrusted),
      ],
      historyMessageIds: [10, 11, 12, 13],
      windowStartMessageId: nil,
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let enriched = TurnRunner.attach([11: alpha, 13: beta], to: snapshot)
    let result = try makeBuilder().assemble(
      snapshot: enriched,
      sessionId: 1,
      origin: .interactive
    )

    // then — each image sits on the row it arrived on, and survives into that row's rendered message
    #expect(enriched.history.map(\.image) == [nil, alpha, nil, beta])
    let first = try #require(
      result.messages.first { message in
        message.content.text.contains("first caption")
      }
    )
    #expect(first.content.images == [alpha])
    let second = try #require(
      result.messages.first { message in
        message.content.text.contains("second caption")
      }
    )
    #expect(second.content.images == [beta])
  }

  @Test func aCachedImageReachesTheProviderOnTheMessageItArrivedOn() async throws {
    // given — a real run whose trigger message has an image waiting in the cache it was handed
    let env = try makeEnv(
      agentOutcome: .respond(
        ChatResponse(
          content: "a photo",
          finishReason: "stop",
          usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
          costFromProvider: 0.0021
        )
      )
    )
    let cache = ImageCache()
    await cache.store(alpha, sessionId: env.sessionId, messageId: env.triggerMessageId)

    // when
    try await env.runner.withImageCache(cache).run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then — the image crossed every stage between the cache and the wire, on exactly one message
    let requests = await env.provider.requests
    let request = try #require(requests.first)
    let carrying = request.messages.filter { message in
      message.content.images.isEmpty == false
    }
    #expect(carrying.count == 1)
    #expect(carrying.first?.content.images == [alpha])
  }

  @Test func theReplayBudgetIsSpentOnlyOnImagesInsideTheHistoryWindow() throws {
    // given — a cached image the window rolled past, big enough to exhaust the aggregate cap alone,
    // and newer than the one still in the window so budgeting would reach it first
    let rolledPast = ImagePart(
      data: Data(repeating: 0xFF, count: ImageBounds.maximumAggregateReplayBytes),
      mediaType: .jpeg,
      width: 4_000,
      height: 3_000
    )
    let snapshot = SessionContextSnapshot(
      history: [StoredMessage(role: .user, content: "caption", provenance: .untrusted)],
      historyMessageIds: [20],
      windowStartMessageId: nil,
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let enriched = TurnRunner.attach([20: alpha, 21: rolledPast], to: snapshot)

    // then
    let attached = try #require(enriched.history.first)
    #expect(attached.image == alpha)
  }

  private func makeBuilder() -> ContextBuilder {
    ContextBuilder(
      systemPrompt: SystemPrompt.minimal,
      workspace: EmptyWorkspace(),
      memoryStore: EmptyMemoryStore(),
      retriever: EmptyRetriever(),
      budget: .default
    )
  }
}
