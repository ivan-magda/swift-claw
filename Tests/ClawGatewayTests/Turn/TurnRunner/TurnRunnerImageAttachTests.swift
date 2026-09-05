import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite struct TurnRunnerImageAttachTests {
  private let alpha = ImagePart(
    data: ImageFixtures.jpeg,
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
      sessionKey: SessionKey.telegramDM(chatId: 42),
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
    await env.imageCache.store(alpha, sessionId: env.sessionId, messageId: env.triggerMessageId)

    // when
    try await env.runner.run(
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

  /// The approval detour is exactly the path a photo takes when its caption asks for something
  /// gated: the second half of that turn runs through `resume`, not `run`, and would answer about
  /// pixels it never received if replay were wired to only one of the two.
  @Test func aCachedImageStillReachesTheProviderOnAResumedRun() async throws {
    // given — a turn suspended on a gated tool, with the trigger message's photo in the cache
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let env = try makeEnv(
      agentOutcome: .respond(
        ChatResponse(
          content: "a photo",
          finishReason: "stop",
          usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
          costFromProvider: 0.0021
        )
      ),
      now: { fixedNow }
    )
    await env.imageCache.store(alpha, sessionId: env.sessionId, messageId: env.triggerMessageId)
    let observationMessageId = try await suspendOnAGatedFetchThenApprove(env: env, now: fixedNow)

    // when
    await env.runner.resume(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      contextBoundMessageId: observationMessageId
    )

    // then — the continuation carries the image on the message it arrived on, exactly as `run` does
    let requests = await env.provider.requests
    let request = try #require(requests.last)
    let carrying = request.messages.filter { message in
      message.content.images.isEmpty == false
    }
    #expect(carrying.count == 1)
    #expect(carrying.first?.content.images == [alpha])
  }

  @Test func theReplayBudgetIsSpentOnlyOnImagesInsideTheHistoryWindow() throws {
    // given — two images each big enough to exhaust the aggregate cap alone: one on an older row
    // still inside the window, one on a row the window rolled past. Budgeting walks newest-first, so
    // the small in-window image is reached first and both giants are then unaffordable.
    let hugeBytes = Data(repeating: 0xFF, count: ImageBounds.maximumAggregateReplayBytes)
    let overBudget = ImagePart(data: hugeBytes, mediaType: .jpeg, width: 4_000, height: 3_000)
    let rolledPast = ImagePart(data: hugeBytes, mediaType: .png, width: 4_000, height: 3_000)
    let snapshot = SessionContextSnapshot(
      sessionKey: SessionKey.telegramDM(chatId: 42),
      history: [
        StoredMessage(role: .user, content: "older caption", provenance: .untrusted),
        StoredMessage(role: .user, content: "newer caption", provenance: .untrusted),
      ],
      historyMessageIds: [20, 21],
      windowStartMessageId: nil,
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let enriched = TurnRunner.attach([20: overBudget, 21: alpha, 22: rolledPast], to: snapshot)

    // then — the affordable image rides, the in-window giant is dropped for want of budget, and the
    // out-of-window giant never billed against that budget in the first place
    #expect(enriched.history.map(\.image) == [nil, alpha])
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
