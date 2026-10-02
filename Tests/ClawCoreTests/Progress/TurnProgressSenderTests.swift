import ClawCore
import ClawTestSupport
import Testing

@Suite
struct TurnProgressSenderTests {
  @Test
  func onlyTheSecondDraftGoesOutOnTheNextProbe() async throws {
    // given
    let clock = ScriptedClock.compressed(parkingAt: .seconds(1))
    let drafts = CadenceDrafts(clock: clock)
    let sender = TurnProgressSender(
      target: .chat(3),
      draftID: 1,
      mode: .legacyProviderRound,
      drafts: drafts,
      typing: RecordingTyping(),
      clock: clock
    ) {
      await drafts.nextFrame()
    }

    // when
    let task = Task {
      await sender.run()
    }
    let arrived = await drafts.third.waitUntilOpen()
    task.cancel()
    await task.value

    // then
    try #require(arrived)
    let sentAt = await drafts.sentAt
    try #require(sentAt.count >= 3)
    let probe = TurnProgressSender.probeInterval
    #expect(sentAt[1] - sentAt[0] == probe)
    #expect(sentAt[2] - sentAt[1] == probe * TurnProgressSender.minTicksBetweenDrafts)
  }

  @Test
  func interactiveSenderRefreshesAnUnchangedFrame() async throws {
    // given
    let clock = ScriptedClock.compressed(parkingAt: .seconds(1))
    let drafts = CadenceDrafts(clock: clock)
    let sender = TurnProgressSender(
      target: .chat(3),
      draftID: 1,
      mode: .interactive,
      drafts: drafts,
      typing: RecordingTyping(),
      clock: clock
    ) {
      TurnProgressFrame(markdown: "unchanged", typingAllowed: true)
    }

    // when
    let task = Task {
      await sender.run()
    }
    let arrived = await drafts.third.waitUntilOpen()
    task.cancel()
    await task.value

    // then
    try #require(arrived)
    let sentAt = await drafts.sentAt
    try #require(sentAt.count >= 3)
    #expect(sentAt[1] - sentAt[0] == .milliseconds(250))
    #expect(sentAt[2] - sentAt[1] == .seconds(25))
  }

  @Test
  func boundedSendReturnsTheDeliveredValue() async {
    // given
    let clock = ScriptedClock { _ in
      await AsyncGate().wait()
      throw CancellationError()
    }

    // when
    let delivered = await TurnProgressSender.sendBounded(timeout: .seconds(3), clock: clock) {
      true
    }

    // then
    #expect(delivered == true)
  }

  @Test
  func boundedSendCancelsAndJoinsTheTimedOutSink() async {
    // given
    let started = AsyncGate()
    let cleaned = AsyncGate()
    let clock = ScriptedClock { _ in
      await started.wait()
    }

    // when
    let delivered = await TurnProgressSender.sendBounded(timeout: .seconds(3), clock: clock) {
      started.open()
      await AsyncGate().wait()
      cleaned.open()
      return false
    }

    // then
    #expect(delivered == nil)
    #expect(cleaned.isOpen)
  }
}

// MARK: - Cadence Boundary

private actor CadenceDrafts: RichDraftStreaming {
  nonisolated let third = AsyncGate()
  private let clock: ScriptedClock
  private let start: ScriptedClock.Instant
  private(set) var sentAt: [Duration] = []

  init(clock: ScriptedClock) {
    self.clock = clock
    start = clock.now
  }

  func nextFrame() -> TurnProgressFrame {
    TurnProgressFrame(
      markdown: String(repeating: "a", count: sentAt.count + 1),
      typingAllowed: true
    )
  }

  func sendDraft(chatID: Int64, draftID: Int64, markdown: String) async -> Bool {
    sentAt.append(start.duration(to: clock.now))
    if sentAt.count == 3 {
      third.open()
    }
    return true
  }
}
