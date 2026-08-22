import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

/// The two cosmetic progress signals a turn emits — the "typing…" action and the streaming draft —
/// have to land in the topic that asked, not in the supergroup's General feed.
@Suite struct TopicProgressSignalTests {
  private func buildResult() -> BuildResult {
    BuildResult(
      messages: [ChatMessage(role: .user, content: "hi")],
      ownerNotices: [],
      hasPrivateDataAccess: false
    )
  }

  private func streamingProvider(replying content: String) -> StreamingProvider {
    StreamingProvider(
      streamScript: .events([
        .delta(content),
        .finished(
          ChatResponse(
            content: content,
            finishReason: "stop",
            usage: ChatUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5),
            costFromProvider: 0.001
          )
        ),
      ])
    )
  }

  @Test func aGroupTurnPulsesTypingIntoTheCallingTopic() async throws {
    // given
    let typing = RecordingTyping()
    let runtime = makeRuntime(
      provider: SequenceProvider([okResponse(content: "ok")]),
      typing: typing
    )

    // when
    _ = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: -1_001,
      buildResult: buildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0,
      mode: .group,
      threadId: 77
    )

    // then
    let pulses = await typing.pulses
    #expect(!pulses.isEmpty)
    #expect(
      pulses.allSatisfy { pulse in
        pulse == RecordingTyping.Pulse(chatId: -1_001, messageThreadId: 77)
      }
    )
  }

  @Test func aGroupStreamingDraftCarriesTheCallingTopic() async throws {
    // given
    let drafts = RecordingDrafts()
    let runtime = makeRuntime(
      provider: streamingProvider(replying: "hello"),
      drafts: drafts,
      streamingEnabled: true
    )

    // when
    _ = try await runtime.runTurn(
      runId: 11,
      sessionId: 22,
      chatId: -1_001,
      buildResult: buildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0,
      mode: .group,
      threadId: 77
    )

    // then
    let sent = await drafts.drafts
    #expect(!sent.isEmpty)
    #expect(sent.allSatisfy { $0.messageThreadId == 77 })
    #expect(sent.allSatisfy { $0.chatId == -1_001 })
  }

  @Test func aDirectTurnPulsesTypingIntoNoThread() async throws {
    // given
    let typing = RecordingTyping()
    let runtime = makeRuntime(
      provider: SequenceProvider([okResponse(content: "ok")]),
      typing: typing
    )

    // when — the DM spelling: no mode, no thread, exactly as before group mode existed
    _ = try await runtime.runTurn(
      runId: 11,
      sessionId: 22,
      chatId: 42,
      buildResult: buildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let pulses = await typing.pulses
    #expect(!pulses.isEmpty)
    #expect(pulses.allSatisfy { $0.messageThreadId == nil })
  }

  @Test func aDirectStreamingDraftCarriesNoThread() async throws {
    // given
    let drafts = RecordingDrafts()
    let runtime = makeRuntime(
      provider: streamingProvider(replying: "hello"),
      drafts: drafts,
      streamingEnabled: true
    )

    // when
    _ = try await runtime.runTurn(
      runId: 11,
      sessionId: 22,
      chatId: 42,
      buildResult: buildResult(),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let sent = await drafts.drafts
    #expect(!sent.isEmpty)
    #expect(sent.allSatisfy { $0.messageThreadId == nil })
  }
}
