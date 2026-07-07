import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

struct TimedStreamEvent: Sendable {
  let pauseBefore: Duration
  let event: StreamEvent
}

actor StreamingProvider: LLMProvider {
  enum StreamScript: Sendable {
    case events([StreamEvent])
    case timed([TimedStreamEvent])
    case gated(TypingReleaseGate, [StreamEvent])
    case gatedBetween([StreamEvent], TypingReleaseGate, [StreamEvent])
    case fail(ProviderError)
    case neverFinishes
    case ignoresCancellation(NonCooperativeStreamGate)
  }

  enum BlockingScript: Sendable {
    case respond(ChatResponse)
    case fail(ProviderError)
  }

  private let streamScript: StreamScript
  private let blockingScript: BlockingScript
  private(set) var completeCalls = 0
  private(set) var streamCalls = 0

  init(
    streamScript: StreamScript,
    blockingScript: BlockingScript = .respond(okResponse(content: "blocking fallback"))
  ) {
    self.streamScript = streamScript
    self.blockingScript = blockingScript
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    completeCalls += 1
    switch blockingScript {
    case .respond(let response): return response
    case .fail(let error): throw error
    }
  }

  nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await self.recordStreamCall()
        switch await self.streamScriptValue() {
        case .events(let events):
          for event in events {
            continuation.yield(event)
          }
          continuation.finish()
        case .timed(let steps):
          for step in steps {
            if step.pauseBefore > .zero {
              try? await Task.sleep(for: step.pauseBefore)
            }
            continuation.yield(step.event)
          }
          continuation.finish()
        case .gated(let gate, let events):
          await gate.awaitRelease()
          for event in events {
            continuation.yield(event)
          }
          continuation.finish()
        case .gatedBetween(let prefix, let gate, let suffix):
          for event in prefix {
            continuation.yield(event)
          }
          await gate.awaitRelease()
          for event in suffix {
            continuation.yield(event)
          }
          continuation.finish()
        case .fail(let error):
          continuation.finish(throwing: error)
        case .neverFinishes:
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
          }
          continuation.finish(throwing: CancellationError())
        case .ignoresCancellation(let gate):
          continuation.yield(.delta("partial"))
          await gate.markStartedAndWaitForRelease()
          continuation.finish(throwing: CancellationError())
        }
      }
      continuation.onTermination = { _ in
        Task {
          if await self.cancelsStreamTaskOnTermination() {
            task.cancel()
          }
        }
      }
    }
  }

  private func recordStreamCall() {
    streamCalls += 1
  }

  private func streamScriptValue() -> StreamScript {
    streamScript
  }

  private func cancelsStreamTaskOnTermination() -> Bool {
    if case .ignoresCancellation = streamScript {
      return false
    }
    return true
  }
}

actor RecordingDrafts: RichDraftStreaming {
  private(set) var drafts: [(chatId: Int64, draftId: Int64, markdown: String)] = []

  func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async {
    drafts.append((chatId, draftId, markdown))
  }
}

/// Records drafts and releases `gate` on its first send, so a mid-stream gate can hold the stream's
/// suffix until the draft/typing loop has drawn its first frame over the prefix state — the empty
/// window the old `.timed(pauseBefore:)` forced with a real 80ms sleep.
actor ReleasingRecordingDrafts: RichDraftStreaming {
  private(set) var drafts: [(chatId: Int64, draftId: Int64, markdown: String)] = []
  private let gate: TypingReleaseGate

  init(gate: TypingReleaseGate) {
    self.gate = gate
  }

  func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async {
    drafts.append((chatId, draftId, markdown))
    await gate.release()
  }
}

/// Streams a DIFFERENT scripted event sequence per `stream` call and records the request each round
/// received. The single-script `StreamingProvider` above replays one fixed script for every call
/// and exposes only a call count, so it can neither terminate a two-round tool loop nor surface the
/// fenced follow-up request — both of which the tool-round-trip test asserts.
actor RecordingStreamingProvider: LLMProvider {
  private var rounds: [[StreamEvent]]
  private(set) var requests: [ChatRequest] = []

  init(rounds: [[StreamEvent]]) {
    self.rounds = rounds
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    // Streaming is enabled and never connect-fails here, so the blocking fallback is unreachable.
    throw ProviderError.terminal(status: nil, message: "blocking path not scripted")
  }

  private func nextRound(recording request: ChatRequest) -> [StreamEvent] {
    requests.append(request)
    guard rounds.isEmpty == false else {
      return []
    }
    return rounds.removeFirst()
  }

  nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        let events = await self.nextRound(recording: request)
        for event in events {
          continuation.yield(event)
        }
        continuation.finish()
      }
    }
  }
}

/// The two streamed rounds for a tool round-trip: round 1 streams a preamble then finishes with a
/// fetch proposal; round 2 streams the answer once the fenced observation has been fed back.
func toolRoundTripStreamRounds() -> [[StreamEvent]] {
  [
    [
      .delta("let me "),
      .delta("check"),
      .finished(
        finishReason: "tool_calls",
        usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
        providerCost: nil,
        toolCalls: [fetchProposal()]
      ),
    ],
    [
      .delta("the page "),
      .delta("says hello"),
      .finished(
        finishReason: "stop",
        usage: ChatUsage(promptTokens: 12, completionTokens: 4, totalTokens: 16),
        providerCost: nil,
        toolCalls: []
      ),
    ],
  ]
}

/// Releases `gate` once typing has been issued `releaseAfter` times, so a test can hold the
/// provider's first token back until the runtime has proven it keeps the indicator alive.
actor CountingReleaseTyping: TypingIndicator {
  private(set) var calls = 0
  private let releaseAfter: Int
  private let gate: TypingReleaseGate

  init(releaseAfter: Int, gate: TypingReleaseGate) {
    self.releaseAfter = releaseAfter
    self.gate = gate
  }

  func sendTyping(chatId: Int64) async {
    calls += 1
    if calls >= releaseAfter {
      await gate.release()
    }
  }
}

/// Blocks the send whose markdown equals the full reply until released, so a test can observe
/// whether the turn awaits its final draft or abandons it.
actor BlockingFinalDrafts: RichDraftStreaming {
  private(set) var drafts: [String] = []
  private let finalMarkdown: String
  private var released = false
  private var finalBlocked = false
  private var blockWaiters: [CheckedContinuation<Void, Never>] = []
  private var observeWaiters: [CheckedContinuation<Void, Never>] = []

  init(finalMarkdown: String) {
    self.finalMarkdown = finalMarkdown
  }

  func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async {
    drafts.append(markdown)
    guard markdown == finalMarkdown, !released else {
      return
    }
    finalBlocked = true
    for waiter in observeWaiters {
      waiter.resume()
    }
    observeWaiters.removeAll()
    await withCheckedContinuation { continuation in
      blockWaiters.append(continuation)
    }
  }

  func waitUntilFinalBlocked() async {
    guard !finalBlocked else { return }
    await withCheckedContinuation { continuation in
      observeWaiters.append(continuation)
    }
  }

  func release() {
    released = true
    for waiter in blockWaiters {
      waiter.resume()
    }
    blockWaiters.removeAll()
  }
}

/// Marks when an async operation has finished, so a test can assert it is still in flight.
actor CompletionFlag {
  private(set) var done = false

  func markDone() {
    done = true
  }
}

/// Compresses every runtime sleep except the wall-clock deadline (180s default) to ~1ms, so
/// throttle ticks and send deadlines elapse instantly while the deadline child stays parked.
let compressedSleep: @Sendable (Duration) async throws -> Void = { duration in
  if duration >= .seconds(10) {
    try await Task.sleep(for: .seconds(3600))
  } else {
    try await Task.sleep(for: .milliseconds(1))
  }
}

/// Parks the per-send draft deadline (3s) and the wall-clock deadline while probe ticks run real,
/// so "the turn awaits the final draft" is asserted time-independently instead of racing the
/// abandon deadline under CI load.
let draftDeadlineParkingSleep: @Sendable (Duration) async throws -> Void = { duration in
  if duration >= .seconds(3) {
    try await Task.sleep(for: .seconds(3600))
  } else {
    try await Task.sleep(for: duration)
  }
}

actor BlockingDrafts: RichDraftStreaming {
  private(set) var drafts: [(chatId: Int64, draftId: Int64, markdown: String)] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private var firstSendBlocked = false

  func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async {
    drafts.append((chatId, draftId, markdown))
    guard drafts.count == 1, !released else {
      return
    }
    firstSendBlocked = true
    for waiter in blockedWaiters {
      waiter.resume()
    }
    blockedWaiters.removeAll()
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func waitUntilFirstSendBlocked() async {
    guard !firstSendBlocked else { return }
    await withCheckedContinuation { continuation in
      blockedWaiters.append(continuation)
    }
  }

  func release() {
    released = true
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
  }
}

actor NonCooperativeStreamGate {
  private var started = false
  private var released = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func markStartedAndWaitForRelease() async {
    started = true
    for waiter in startedWaiters {
      waiter.resume()
    }
    startedWaiters.removeAll()

    guard !released else { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startedWaiters.append(continuation)
    }
  }

  func release() {
    released = true
    for waiter in releaseWaiters {
      waiter.resume()
    }
    releaseWaiters.removeAll()
  }
}

enum TimedTurnResult: Sendable {
  case result(TurnOutcome)
  case timeout
}

actor TurnResultBox {
  private var result: TimedTurnResult?
  private var waiters: [CheckedContinuation<TimedTurnResult, Never>] = []

  func resolve(_ result: TimedTurnResult) {
    guard self.result == nil else { return }
    self.result = result
    for waiter in waiters {
      waiter.resume(returning: result)
    }
    waiters.removeAll()
  }

  func wait() async -> TimedTurnResult {
    if let result {
      return result
    }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

/// `runTurn` now throws (`StoreError.diskFull` only); none of these scripted races configure a
/// failing usage/audit store, so a throw here is a test-harness bug, not a scenario under test —
/// recorded as a failure rather than silently swallowed.
func startTurn(
  operation: @escaping @Sendable () async throws -> TurnOutcome
) -> TurnResultBox {
  let box = TurnResultBox()
  Task {
    do {
      await box.resolve(.result(try await operation()))
    } catch {
      Issue.record("unexpected runTurn throw in test harness: \(error)")
      await box.resolve(.timeout)
    }
  }
  return box
}

func waitForTurnResult(
  _ result: TurnResultBox,
  milliseconds: Int
) async -> TurnOutcome? {
  let timeout = Task {
    try? await Task.sleep(for: .milliseconds(milliseconds))
    await result.resolve(.timeout)
  }

  switch await result.wait() {
  case .result(let result):
    timeout.cancel()
    return result
  case .timeout:
    return nil
  }
}

@Suite struct AgentRuntimeStreamingTests {
  private func singleUserBuildResult(_ content: String) -> BuildResult {
    BuildResult(
      messages: [ChatMessage(role: .user, content: content)],
      ownerNotices: [],
      hasPrivateDataAccess: false
    )
  }

  @Test func streamingTurnPublishesDraftsAndCompletesWithAccumulatedContent() async throws {
    // given
    let provider = StreamingProvider(
      streamScript: .events([
        .delta("he"),
        .delta("llo"),
        .finished(
          finishReason: "stop",
          usage: ChatUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5),
          providerCost: 0.001,
          toolCalls: []
        ),
      ])
    )
    let drafts = RecordingDrafts()
    let runtime = makeRuntime(provider: provider, drafts: drafts, streamingEnabled: true)

    // when
    let outcome = try await runtime.runTurn(
      runId: 11,
      sessionId: 22,
      chatId: 33,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, usage) = try requireCompleted(outcome.result)
    #expect(content == "hello")
    #expect(usage.promptTokens == 3)
    #expect(usage.completionTokens == 2)
    #expect(usage.costUSD == 0.001)
    let sentDrafts = await drafts.drafts
    #expect(sentDrafts.count >= 1)
    #expect(sentDrafts.map(\.draftId).allSatisfy { $0 == 11 })
    #expect(sentDrafts.last?.markdown == "hello")
    #expect(await provider.completeCalls == 0)
    #expect(await provider.streamCalls == 1)
  }

  @Test func typingIsReissuedWhileWaitingForTheFirstToken() async throws {
    // given
    let gate = TypingReleaseGate()
    let typing = CountingReleaseTyping(releaseAfter: 3, gate: gate)
    let tickYieldingSleep: @Sendable (Duration) async throws -> Void = { duration in
      if duration >= .seconds(10) {
        try await Task.sleep(for: .seconds(3600))
      } else {
        await Task.yield()
      }
    }
    let provider = StreamingProvider(
      streamScript: .gated(
        gate,
        [
          .delta("hi"),
          .finished(finishReason: "stop", usage: nil, providerCost: nil, toolCalls: []),
        ]
      )
    )
    let runtime = makeRuntime(
      provider: provider,
      typing: typing,
      streamingEnabled: true,
      sleep: tickYieldingSleep
    )

    // when
    let turnResult = startTurn {
      try await runtime.runTurn(
        runId: 1,
        sessionId: 2,
        chatId: 3,
        buildResult: self.singleUserBuildResult("hi"),
        sessionTainted: false,
        grant: nil,
        todayTokens: 0,
        todayUSD: 0
      )
    }
    let outcome = await waitForTurnResult(turnResult, milliseconds: 2_000)

    // then
    let (content, _) = try requireCompleted(try #require(outcome).result)
    #expect(content == "hi")
    #expect(await typing.calls >= 3)
  }

  @Test func emptyFirstDeltaNeverProducesABlankDraft() async throws {
    // given
    // The gate withholds "hello" until the draft/typing loop has drawn its first frame over the
    // empty accumulation — the ordering the old `.timed(pauseBefore:)` forced with 80ms of real
    // sleep. Correct code publishes nothing for the empty delta, so the loop's first frame is a
    // typing pulse (releases via `CountingReleaseTyping`); a regressed guard would publish "" and
    // the loop's frame becomes a blank draft (releases via `ReleasingRecordingDrafts`) — caught by
    // the non-empty assertion. Either path releases the shared gate, so the stream never wedges.
    let gate = TypingReleaseGate()
    let provider = StreamingProvider(
      streamScript: .gatedBetween(
        [.delta("")],
        gate,
        [
          .delta("hello"),
          .finished(finishReason: "stop", usage: nil, providerCost: nil, toolCalls: []),
        ]
      )
    )
    let drafts = ReleasingRecordingDrafts(gate: gate)
    let typing = CountingReleaseTyping(releaseAfter: 1, gate: gate)
    let runtime = makeRuntime(
      provider: provider,
      typing: typing,
      drafts: drafts,
      streamingEnabled: true,
      sleep: compressedSleep
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 11,
      sessionId: 22,
      chatId: 33,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, _) = try requireCompleted(outcome.result)
    #expect(content == "hello")
    let sentDrafts = await drafts.drafts
    #expect(!sentDrafts.isEmpty)
    #expect(sentDrafts.allSatisfy { !$0.markdown.isEmpty })
  }

  @Test func turnAwaitsTheFinalDraftSend() async throws {
    // given
    let provider = StreamingProvider(
      streamScript: .events([
        .delta("hel"),
        .delta("lo"),
        .finished(finishReason: "stop", usage: nil, providerCost: nil, toolCalls: []),
      ])
    )
    let drafts = BlockingFinalDrafts(finalMarkdown: "hello")
    let runtime = makeRuntime(
      provider: provider,
      drafts: drafts,
      streamingEnabled: true,
      sleep: draftDeadlineParkingSleep
    )
    let flag = CompletionFlag()

    // when
    let turnTask = Task {
      let outcome = try await runtime.runTurn(
        runId: 1,
        sessionId: 2,
        chatId: 3,
        buildResult: singleUserBuildResult("hi"),
        sessionTainted: false,
        grant: nil,
        todayTokens: 0,
        todayUSD: 0
      )
      await flag.markDone()
      return outcome
    }
    await drafts.waitUntilFinalBlocked()
    // The turn is now suspended inside the final draft send; a yield lets any (incorrect)
    // fire-and-forget completion surface before we snapshot, without a wall-clock window.
    await Task.yield()
    let doneWhileFinalSendBlocked = await flag.done
    await drafts.release()
    let outcome = try await turnTask.value

    // then
    #expect(doneWhileFinalSendBlocked == false)
    let (content, _) = try requireCompleted(outcome.result)
    #expect(content == "hello")
    #expect(await drafts.drafts.contains("hello"))
  }

  @Test func externalCancellationNeverCompletesWithPartialContent() async throws {
    // A /stop-style cancel mid-stream must degrade the turn, never surface the partial
    // accumulation as a completed reply. AsyncThrowingStream ends iteration with nil on consumer
    // cancellation (it does not throw), so the EOF path must re-check cancellation. The wall-clock
    // deadline child always throws a competing CancellationError on cancel, so one run can mask a
    // removed re-check — loop it. (A gate now arms the "partial" accumulation deterministically,
    // replacing the old 10ms sleep.)
    for _ in 0..<20 {
      // given
      let gate = NonCooperativeStreamGate()
      let provider = StreamingProvider(streamScript: .ignoresCancellation(gate))
      let drafts = BlockingDrafts()
      let runtime = makeRuntime(
        provider: provider,
        drafts: drafts,
        streamingEnabled: true,
        sleep: compressedSleep
      )

      // when
      let turnTask = Task {
        try await runtime.runTurn(
          runId: 1,
          sessionId: 2,
          chatId: 3,
          buildResult: singleUserBuildResult("hi"),
          sessionTainted: false,
          grant: nil,
          todayTokens: 0,
          todayUSD: 0
        )
      }
      await gate.waitUntilStarted()
      // The first draft send can only happen after `consumeStream` published "partial", so blocking
      // on it arms the re-check regression deterministically, without a wall-clock window.
      await drafts.waitUntilFirstSendBlocked()
      turnTask.cancel()
      let outcome = try await turnTask.value
      await gate.release()
      await drafts.release()

      // then
      let (kind, _) = try requireDegraded(outcome.result)
      #expect(kind == .providerUnavailable)
    }
  }

  @Test func streamingToolRoundTripFencesObservationIntoFollowUpRequest() async throws {
    // given — round 1 streams a preamble then finishes with a tool proposal; round 2 streams the
    // answer once the fenced observation has been fed back
    let provider = RecordingStreamingProvider(rounds: toolRoundTripStreamRounds())
    let dispatcher = ScriptedDispatcher(respond: okOutcome(content: "page text"))
    let runtime = makeRuntime(
      provider: provider,
      streamingEnabled: true,
      toolDispatcher: dispatcher
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 11,
      sessionId: 22,
      chatId: 33,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the streamed round-trip completes with round 2's accumulated answer; the executed
    // observation is recorded RAW in the exchange and tainted the run (mirrors the blocking path)
    let completed = try requireCompleted(outcome.result)
    #expect(completed.content == "the page says hello")
    #expect(outcome.exchanges.count == 1)
    #expect(outcome.exchanges[0].assistantContent == "let me check")
    #expect(outcome.exchanges[0].observations[0].content == "page text")
    #expect(outcome.ingestedUntrusted)

    // and the follow-up streamed request carried the anchor + the FENCED observation (§6.5/§12)
    let secondRequest = await provider.requests[1]
    let anchor = secondRequest.messages[secondRequest.messages.count - 2]
    #expect(anchor.role == .assistant)
    #expect(anchor.toolCalls.map(\.id) == ["c1"])
    let observationMessage = secondRequest.messages[secondRequest.messages.count - 1]
    #expect(observationMessage.role == .tool)
    #expect(observationMessage.toolCallId == "c1")
    #expect(observationMessage.content.contains("<claw-untrusted"))
    #expect(observationMessage.content.contains("page text"))
    #expect(await provider.requests.count == 2)
  }

  @Test func streamingDisabledUsesBlockingCompletePath() async throws {
    // given
    let provider = StreamingProvider(streamScript: .events([.delta("ignored")]))
    let runtime = makeRuntime(provider: provider, streamingEnabled: false)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, _) = try requireCompleted(outcome.result)
    #expect(content == "blocking fallback")
    #expect(await provider.completeCalls == 1)
    #expect(await provider.streamCalls == 0)
  }

  @Test func streamingDisabledConnectFailureDoesNotCallBlockingCompleteTwice() async throws {
    // given
    let provider = StreamingProvider(
      streamScript: .events([.delta("ignored")]),
      blockingScript: .fail(.connectFailed(message: "refused"))
    )
    let runtime = makeRuntime(provider: provider, streamingEnabled: false)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(try #require(usage).isEstimated)
    #expect(await provider.completeCalls == 1)
    #expect(await provider.streamCalls == 0)
  }

  @Test func connectFailureFallsBackToBlockingCompleteOnce() async throws {
    // given
    let provider = StreamingProvider(streamScript: .fail(.connectFailed(message: "refused")))
    let runtime = makeRuntime(provider: provider, streamingEnabled: true)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, _) = try requireCompleted(outcome.result)
    #expect(content == "blocking fallback")
    #expect(await provider.streamCalls == 1)
    #expect(await provider.completeCalls == 1)
  }

  @Test func streamingResponseDoesNotWaitForBlockedDraftSend() async throws {
    // given
    let provider = StreamingProvider(
      streamScript: .events([
        .delta("he"),
        .delta("llo"),
        .finished(
          finishReason: "stop",
          usage: ChatUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5),
          providerCost: 0.001,
          toolCalls: []
        ),
      ])
    )
    let drafts = BlockingDrafts()
    // Compressed sleep so the per-send abandon deadline elapses instantly: the invariant under
    // test is that a sink which never returns still cannot block turn completion.
    let runtime = makeRuntime(
      provider: provider,
      drafts: drafts,
      streamingEnabled: true,
      sleep: compressedSleep
    )

    // when
    let turnResult = startTurn {
      try await runtime.runTurn(
        runId: 11,
        sessionId: 22,
        chatId: 33,
        buildResult: self.singleUserBuildResult("hi"),
        sessionTainted: false,
        grant: nil,
        todayTokens: 0,
        todayUSD: 0
      )
    }
    await drafts.waitUntilFirstSendBlocked()
    let outcome = await waitForTurnResult(turnResult, milliseconds: 1_000)

    // then
    await drafts.release()
    let completed = try requireCompleted(try #require(outcome).result)
    #expect(completed.content == "hello")
    #expect(await provider.completeCalls == 0)
    #expect(await provider.streamCalls == 1)
  }

  @Test func postSendStreamFailureDegradesWithoutBlockingFallback() async throws {
    // given
    let provider = StreamingProvider(streamScript: .fail(.retryable(status: nil, message: "drop")))
    let runtime = makeRuntime(provider: provider, streamingEnabled: true)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hello world"),
      sessionTainted: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(try #require(usage).isEstimated)
    #expect(await provider.completeCalls == 0)
  }

  @Test func terminalStreamFailureDegradesAndDebitsTheEstimate() async throws {
    // given
    let provider = StreamingProvider(streamScript: .fail(.terminal(status: 400, message: "bad")))
    let runtime = makeRuntime(provider: provider, streamingEnabled: true)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hello world"),
      sessionTainted: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(try #require(usage).isEstimated)
    #expect(await provider.completeCalls == 0)
    #expect(await provider.streamCalls == 1)
  }

  @Test func oversizedAccumulatedStreamContentDegradesWithoutBlockingFallback() async throws {
    for events in oversizedStreamCases() {
      // given
      let provider = StreamingProvider(streamScript: .events(events))
      let runtime = makeRuntime(provider: provider, streamingEnabled: true)

      // when
      let outcome = try await runtime.runTurn(
        runId: 1,
        sessionId: 2,
        chatId: 3,
        buildResult: singleUserBuildResult("hello world"),
        sessionTainted: false,
        grant: nil,
        todayTokens: 0,
        todayUSD: 0
      )

      // then
      let (kind, usage) = try requireDegraded(outcome.result)
      #expect(kind == .providerUnavailable)
      #expect(try #require(usage).isEstimated)
      #expect(await provider.completeCalls == 0)
      #expect(await provider.streamCalls == 1)
    }
  }

  @Test func streamingDeadlineTerminatesNeverEndingStream() async throws {
    // given
    let provider = StreamingProvider(streamScript: .neverFinishes)
    let runtime = makeRuntime(provider: provider, streamingEnabled: true, sleep: { _ in })

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hello world"),
      sessionTainted: false,
      grant: nil,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(try #require(usage).isEstimated)
  }

  @Test func streamingDeadlineTerminatesStreamThatIgnoresCancellation() async throws {
    // given
    let gate = NonCooperativeStreamGate()
    let provider = StreamingProvider(streamScript: .ignoresCancellation(gate))
    let runtime = makeRuntime(provider: provider, streamingEnabled: true, sleep: { _ in })

    // when
    let turnResult = startTurn {
      try await runtime.runTurn(
        runId: 1,
        sessionId: 2,
        chatId: 3,
        buildResult: self.singleUserBuildResult("hello world"),
        sessionTainted: false,
        grant: nil,
        todayTokens: 0,
        todayUSD: 0
      )
    }
    await gate.waitUntilStarted()
    let outcome = await waitForTurnResult(turnResult, milliseconds: 250)

    // then
    await gate.release()
    let (kind, usage) = try requireDegraded(try #require(outcome).result)
    #expect(kind == .providerUnavailable)
    #expect(try #require(usage).isEstimated)
  }

  private func oversizedStreamCases() -> [[StreamEvent]] {
    let chunkByteCount = LLMStreamLimits.maxEventBytes / 4
    let chunk = String(repeating: "a", count: chunkByteCount)
    let cumulativeOverflowDeltas = Array(
      repeating: StreamEvent.delta(chunk),
      count: (LLMStreamLimits.maxAccumulatedContentBytes / chunk.utf8.count) + 1
    )
    let singleOversizedDelta = [
      StreamEvent.delta(
        String(repeating: "a", count: LLMStreamLimits.maxAccumulatedContentBytes + 1)
      )
    ]
    return [cumulativeOverflowDeltas, singleOversizedDelta]
  }
}
