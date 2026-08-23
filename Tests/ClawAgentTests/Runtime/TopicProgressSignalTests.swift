import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

private actor DirectDraftProgressProbe: TypingIndicator, RichDraftStreaming {
  private(set) var drafts: [String] = []
  private(set) var postDraftTypingCount = 0
  private var postDraftTicks = 0

  func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async -> Bool {
    drafts.append(markdown)
    return true
  }

  func sendTyping(chatId: Int64, messageThreadId: Int64?) async {
    if drafts.isEmpty == false {
      postDraftTypingCount += 1
    }
  }

  func advanceProbeTick() -> Bool {
    guard drafts.isEmpty == false else {
      return false
    }
    postDraftTicks += 1
    return postDraftTicks >= 20
  }
}

/// A turn's cosmetic progress signals have to reach the topic that asked, not the supergroup's
/// General feed. Telegram takes a draft only in a private chat, so in a topic that leaves the
/// "typing…" action carrying the whole job — and it has to keep carrying it.
@Suite struct TopicProgressSignalTests {
  private func buildResult() -> BuildResult {
    BuildResult(
      messages: [ChatMessage(role: .user, content: "hi")],
      ownerNotices: [],
      hasPrivateDataAccess: false
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

  /// Telegram accepts a draft only in a private chat, so the bubble never appears in a topic. The
  /// typing pulse is the topic's only progress signal and has to keep going for the whole streaming
  /// turn — an undelivered draft must not be mistaken for a bubble that took the pulse's place.
  ///
  /// The gate holds the stream's terminal until three pulses have gone out *after* the first delta,
  /// so a regression that stops pulsing once a draft has been attempted deadlocks the script rather
  /// than passing on a lucky tick.
  @Test func aGroupStreamingTurnKeepsPulsingTypingWhenNoDraftLands() async throws {
    // given
    let gate = TypingReleaseGate()
    let typing = CountingReleaseTyping(releaseAfter: 3, gate: gate)
    let provider = StreamingProvider(
      streamScript: .gatedBetween(
        [.delta("hel")],
        gate,
        [
          .finished(
            ChatResponse(content: "hello", finishReason: "stop", usage: nil, costFromProvider: nil)
          )
        ]
      )
    )
    let runtime = makeRuntime(
      provider: provider,
      typing: typing,
      drafts: NoopRichDraftStreaming(),
      streamingEnabled: true,
      clock: ScriptedClock.compressed(parkingAt: .seconds(10))
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
    let pulses = await typing.pulses
    #expect(pulses.count >= 3)
    #expect(
      pulses.allSatisfy { pulse in
        pulse == RecordingTyping.Pulse(chatId: -1_001, messageThreadId: 77)
      }
    )
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

  /// The DM counterpart: a delivered draft is the bubble, so it takes the typing action's place
  /// rather than pulsing alongside it.
  @Test func aDirectStreamingDraftSilencesTheTypingPulse() async throws {
    // given — hold the stream open for a full typing interval after the first draft lands
    let terminalGate = TypingReleaseGate()
    let progress = DirectDraftProgressProbe()
    let provider = StreamingProvider(
      streamScript: .gatedBetween(
        [.delta("hello")],
        terminalGate,
        [
          .finished(
            ChatResponse(
              content: "hello",
              finishReason: "stop",
              usage: ChatUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5),
              costFromProvider: 0.001
            )
          )
        ]
      )
    )
    let clock = ScriptedClock { delay in
      guard delay == .milliseconds(250) else {
        try await Task.sleep(for: .seconds(3600))
        return
      }
      if await progress.advanceProbeTick() {
        await terminalGate.release()
      }
      await Task.yield()
    }
    let runtime = makeRuntime(
      provider: provider,
      typing: progress,
      drafts: progress,
      streamingEnabled: true,
      clock: clock
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
    let sent = await progress.drafts
    #expect(!sent.isEmpty)
    #expect(await progress.postDraftTypingCount == 0)
  }
}
