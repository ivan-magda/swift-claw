import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawTelegram
import ClawTestSupport
import Foundation

// MARK: - Fixtures

func progressScope(mode: ChatMode = .direct) -> TurnScope {
  TurnScope(
    runID: 41,
    sessionID: 7,
    chatID: mode == .direct ? 99 : -99,
    threadID: mode == .direct ? nil : 17,
    mode: mode,
    origin: .interactive,
    requesterUserID: 99
  )
}

func makePresentations(
  clock: ScriptedClock,
  drafts: any RichDraftStreaming,
  typing: any TypingIndicator,
  streamingEnabled: Bool = true,
  progressEnabled: Bool = true,
  actionEmojisEnabled: Bool = false,
  outbox: (any OutboxStore)? = nil,
  draftIDs: (any DraftIDStore)? = nil
) throws -> TurnPresentationRegistry {
  TurnPresentationRegistry(
    streamingEnabled: streamingEnabled,
    progressEnabled: progressEnabled,
    renderer: TelegramProgressRenderer(actionEmojisEnabled: actionEmojisEnabled),
    drafts: drafts,
    typing: typing,
    outbox: try outbox ?? OutboxStoreGRDB(writer: TestDatabase.make()),
    draftIDs: try draftIDs ?? DraftIDStoreGRDB(writer: TestDatabase.make()),
    secretValues: [],
    clock: clock
  )
}

actor ProgressDrafts: RichDraftStreaming {
  struct Sent: Sendable {
    let draftID: Int64
    let time: Duration
    let accepted: Bool
    let markdown: String
  }

  let clock: ScriptedClock
  let start: ScriptedClock.Instant
  let rejectAfter: Duration
  private(set) var sent: [Sent] = []

  init(clock: ScriptedClock, rejectAfter: Duration) {
    self.clock = clock
    start = clock.now
    self.rejectAfter = rejectAfter
  }

  func sendDraft(chatID: Int64, draftID: Int64, markdown: String) async -> Bool {
    let time = start.duration(to: clock.now)
    let accepted = time < rejectAfter
    sent.append(Sent(draftID: draftID, time: time, accepted: accepted, markdown: markdown))
    return accepted
  }
}

actor ProgressTyping: TypingIndicator {
  let clock: ScriptedClock
  let start: ScriptedClock.Instant
  let signalAfter: Duration
  let signal: AsyncGate
  private(set) var targets: [DeliveryTarget] = []

  init(clock: ScriptedClock, signalAfter: Duration, signal: AsyncGate) {
    self.clock = clock
    start = clock.now
    self.signalAfter = signalAfter
    self.signal = signal
  }

  func sendTyping(chatID: Int64, messageThreadID: Int64?) async {
    if start.duration(to: clock.now) >= signalAfter {
      targets.append(DeliveryTarget(chatID: chatID, messageThreadID: messageThreadID))
      signal.open()
    }
  }
}

actor ClosingDrafts: RichDraftStreaming {
  nonisolated let started = AsyncGate()
  nonisolated let cancelled = AsyncGate()
  nonisolated let releaseCleanup = AsyncGate()
  nonisolated let cleaned = AsyncGate()
  nonisolated let waitingAfterCleanup = AsyncGate()
  private let blockingText: String?
  private let blockingCall: Int
  private var hasBlocked = false
  private(set) var calls = 0
  private(set) var markdowns: [String] = []
  private(set) var draftIDs: [Int64] = []

  init(blockingText: String? = nil, blockingCall: Int = 1) {
    self.blockingText = blockingText
    self.blockingCall = blockingCall
  }

  func sendDraft(chatID: Int64, draftID: Int64, markdown: String) async -> Bool {
    calls += 1
    markdowns.append(markdown)
    draftIDs.append(draftID)
    if cleaned.isOpen, markdown.contains("Waiting for your approval") {
      waitingAfterCleanup.open()
    }
    guard !hasBlocked, calls >= blockingCall, blockingText.map({ markdown.contains($0) }) ?? true
    else {
      return true
    }
    hasBlocked = true
    started.open()
    await AsyncGate().wait()
    cancelled.open()
    await releaseCleanup.waitIgnoringCancellation()
    cleaned.open()
    return false
  }
}

/// Each probe's arrival proves the previous iteration and all its sends have completed.
actor PresentationProbes {
  private var probeIndex = 0
  private var arrivals: [Int: AsyncGate] = [:]
  private var releases: [Int: AsyncGate] = [:]

  nonisolated var clock: ScriptedClock {
    ScriptedClock { delay in
      if delay >= .seconds(1) {
        await AsyncGate().wait()
        throw CancellationError()
      }
      try await self.sleep()
    }
  }

  func ready() async -> Bool {
    await arrival(probeIndex == 0 ? 1 : probeIndex).waitUntilOpen()
  }

  func advance(_ ticks: Int) async -> Bool {
    for _ in 0..<ticks {
      guard await ready() else {
        return false
      }
      let next = probeIndex + 1
      release(probeIndex).open()
      guard await arrival(next).waitUntilOpen() else {
        return false
      }
    }
    return true
  }
}

// MARK: - Probe Gates

private extension PresentationProbes {
  func sleep() async throws {
    probeIndex += 1
    arrival(probeIndex).open()
    await release(probeIndex).wait()
    try Task.checkCancellation()
  }

  func arrival(_ index: Int) -> AsyncGate {
    if let gate = arrivals[index] {
      return gate
    }
    let gate = AsyncGate()
    arrivals[index] = gate
    return gate
  }

  func release(_ index: Int) -> AsyncGate {
    if let gate = releases[index] {
      return gate
    }
    let gate = AsyncGate()
    releases[index] = gate
    return gate
  }
}
