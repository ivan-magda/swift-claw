import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

struct TimedStreamEvent: Sendable {
  let pauseBefore: Duration
  let event: StreamEvent
}

@Test func terminalResponseIsReconciledAgainstTheAttemptOutputLimit() async throws {
  // given — this provider never observes the scope incrementally, so only the runtime's terminal
  // reconciliation can catch the oversized authoritative response
  let provider = StubProvider(
    .respond(
      ChatResponse(
        content: "12345",
        finishReason: "stop",
        usage: ChatUsage(promptTokens: 2, completionTokens: 2, totalTokens: 4),
        costFromProvider: nil
      )
    )
  )
  let runtime = makeRuntime(
    provider: provider,
    attemptOutputLimits: AttemptOutputLimits(maximumUTF8Bytes: 4, maximumGraphemes: 4)
  )

  // when
  let outcome = try await runtime.runTurn(
    runId: 1,
    sessionId: 2,
    chatId: 3,
    buildResult: makeBuildResult(),
    sessionTainted: false,
    sessionHasPrivateData: false,
    todayTokens: 0,
    todayUSD: 0
  )

  // then
  let degraded = try requireDegraded(outcome.result)
  #expect(degraded.kind == .providerUnavailable)
  #expect(degraded.usage != nil)
  #expect(outcome.attemptDiagnostics.failureCause == .localOutputLimit)
  #expect(outcome.attemptDiagnostics.outputCounts?.limitExceeded == true)
  #expect(outcome.attemptDiagnostics.outputCounts?.utf8Bytes == 5)
}

actor StreamingProvider: LLMProvider {
  enum StreamScript: Sendable {
    case events([StreamEvent])
    case timed([TimedStreamEvent])
    case gated(TypingReleaseGate, [StreamEvent])
    case gatedBetween([StreamEvent], TypingReleaseGate, [StreamEvent])
    /// Carries the provider's own disposition, not just the cause, so a test states whether the
    /// failed attempt could already owe tokens — the fact the runtime's accounting reads.
    case fail(ProviderFailure)
    /// Reports the given cancellation disposition as the stream's terminal without sending anything,
    /// exercising `error(for:)`'s mapping of a `.cancelled(.notStarted)`/`.mayHaveStarted` terminal.
    case reportsCancel(ProviderFailureAccounting)
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

  nonisolated func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make { sink in
      await self.recordStreamCall()
      switch await self.streamScriptValue() {
      case .events(let events):
        return await Self.play(events, into: sink) ?? .completed(Self.emptyReply)
      case .timed(let steps):
        for step in steps {
          if step.pauseBefore > .zero {
            try? await Task.sleep(for: step.pauseBefore)
          }
          if let terminal = await Self.send(step.event, into: sink) {
            return terminal
          }
        }
        return .completed(Self.emptyReply)
      case .gated(let gate, let events):
        await gate.awaitRelease()
        return await Self.play(events, into: sink) ?? .completed(Self.emptyReply)
      case .gatedBetween(let prefix, let gate, let suffix):
        if let terminal = await Self.play(prefix, into: sink) {
          return terminal
        }
        await gate.awaitRelease()
        return await Self.play(suffix, into: sink) ?? .completed(Self.emptyReply)
      case .fail(let failure):
        return .failed(failure)
      case .reportsCancel(let accounting):
        return .cancelled(accounting)
      case .neverFinishes:
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(10))
        }
        return .cancelled(.mayHaveStarted(observing: 0))
      case .ignoresCancellation(let gate):
        _ = await Self.send(.delta("partial"), into: sink)
        // Acknowledges cancellation only once the gate opens, so a test can hold the inference past
        // the runtime's own cancellation and watch what the runtime does about it.
        await gate.markStartedAndWaitForRelease()
        return .cancelled(.mayHaveStarted(observing: 0))
      }
    }
  }

  /// Replays a script, returning the terminal its `.finished` names — or nil when the script runs
  /// out without one, which is how a caller tells "the script ended" from "the stream ended".
  private static func play(
    _ events: [StreamEvent],
    into sink: LLMEventSink
  ) async -> LLMStreamTermination? {
    for event in events {
      if let terminal = await send(event, into: sink) {
        return terminal
      }
    }
    return nil
  }

  /// Returns the terminal once the script reaches one, or once the consumer has stopped listening.
  private static func send(
    _ event: StreamEvent,
    into sink: LLMEventSink
  ) async -> LLMStreamTermination? {
    switch event {
    case .delta(let text):
      do {
        try await sink.sendDelta(text)
        return nil
      } catch {
        return .cancelled(.mayHaveStarted(observing: 0))
      }
    case .finished(let response):
      return .completed(response)
    }
  }

  private static let emptyReply = ChatResponse(
    content: "",
    finishReason: nil,
    usage: nil,
    costFromProvider: nil
  )

  private func recordStreamCall() {
    streamCalls += 1
  }

  private func streamScriptValue() -> StreamScript {
    streamScript
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

  nonisolated func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make { sink in
      let events = await self.nextRound(recording: request)
      for event in events {
        switch event {
        case .delta(let text):
          try? await sink.sendDelta(text)
        case .finished(let response):
          return .completed(response)
        }
      }
      return .completed(
        ChatResponse(content: "", finishReason: nil, usage: nil, costFromProvider: nil)
      )
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
        ChatResponse(
          content: "let me check",
          finishReason: "tool_calls",
          usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
          costFromProvider: nil,
          toolCalls: [fetchProposal()]
        )
      ),
    ],
    [
      .delta("the page "),
      .delta("says hello"),
      .finished(
        ChatResponse(
          content: "the page says hello",
          finishReason: "stop",
          usage: ChatUsage(promptTokens: 12, completionTokens: 4, totalTokens: 16),
          costFromProvider: nil
        )
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
  private var cancelled = false
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
    // The bounded-send coordinator now cancels AND drains an abandoned send, so a blocked send must
    // unwind on cancellation or the drain would wedge — exactly as a production HTTP POST does.
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if cancelled || released {
          continuation.resume()
        } else {
          waiters.append(continuation)
        }
      }
    } onCancel: {
      Task { await self.cancelWaiters() }
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
    resumeWaiters()
  }

  private func cancelWaiters() {
    cancelled = true
    resumeWaiters()
  }

  private func resumeWaiters() {
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

/// The ceiling is a liveness backstop, never a synchronization point: it is cancelled the moment
/// the turn resolves, so it must be generous enough to survive a CPU-starved CI runner.
func waitForTurnResult(
  _ result: TurnResultBox,
  ceiling: Duration = .seconds(30)
) async -> TurnOutcome? {
  let timeout = Task {
    try? await Task.sleep(for: ceiling)
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

// One cohesive @Suite of streaming-turn behaviors sharing the fixtures/helpers declared here;
// splitting would scatter thematically paired tests.
// swiftlint:disable:next type_body_length
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
          ChatResponse(
            content: "hello",
            finishReason: "stop",
            usage: ChatUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5),
            costFromProvider: 0.001
          )
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
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, usage, _) = try requireCompleted(outcome.result)
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
          .finished(
            ChatResponse(content: "hi", finishReason: "stop", usage: nil, costFromProvider: nil)
          ),
        ]
      )
    )
    let runtime = makeRuntime(
      provider: provider,
      typing: typing,
      streamingEnabled: true,
      clock: ScriptedClock(tickYieldingSleep)
    )

    // when
    let turnResult = startTurn {
      try await runtime.runTurn(
        runId: 1,
        sessionId: 2,
        chatId: 3,
        buildResult: self.singleUserBuildResult("hi"),
        sessionTainted: false,
        sessionHasPrivateData: false,
        todayTokens: 0,
        todayUSD: 0
      )
    }
    let outcome = await waitForTurnResult(turnResult)

    // then
    let (content, _, _) = try requireCompleted(try #require(outcome).result)
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
          .finished(
            ChatResponse(content: "hello", finishReason: "stop", usage: nil, costFromProvider: nil)
          ),
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
      clock: ScriptedClock.compressed(parkingAt: .seconds(10))
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 11,
      sessionId: 22,
      chatId: 33,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, _, _) = try requireCompleted(outcome.result)
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
        .finished(
          ChatResponse(content: "hello", finishReason: "stop", usage: nil, costFromProvider: nil)
        ),
      ])
    )
    let drafts = BlockingFinalDrafts(finalMarkdown: "hello")
    let runtime = makeRuntime(
      provider: provider,
      drafts: drafts,
      streamingEnabled: true,
      clock: ScriptedClock(draftDeadlineParkingSleep)
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
        sessionHasPrivateData: false,
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
    let (content, _, _) = try requireCompleted(outcome.result)
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
        clock: ScriptedClock.compressed(parkingAt: .seconds(10))
      )

      // when
      let turnTask = Task {
        try await runtime.runTurn(
          runId: 1,
          sessionId: 2,
          chatId: 3,
          buildResult: singleUserBuildResult("hi"),
          sessionTainted: false,
          sessionHasPrivateData: false,
          todayTokens: 0,
          todayUSD: 0
        )
      }
      await gate.waitUntilStarted()
      // The first draft send can only happen after `consumeStream` published "partial", so blocking
      // on it arms the re-check regression deterministically, without a wall-clock window.
      await drafts.waitUntilFirstSendBlocked()
      turnTask.cancel()
      // The turn joins the session it owns, so the inference has to be let go of before the turn
      // can return — releasing after the join would wait on each other forever.
      await gate.release()
      await drafts.release()
      let outcome = try await turnTask.value

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
      sessionHasPrivateData: false,
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
    #expect(observationMessage.content.text.contains("<claw-untrusted"))
    #expect(observationMessage.content.text.contains("page text"))
    #expect(await provider.requests.count == 2)
  }

  @Test func twoRoundToolExchangeSharesOneAttemptOutputLimit() async throws {
    // given — each terminal response fits under ten bytes in isolation. Their combined emitted
    // output does not, so this only fails when the runtime carries one limiter across both calls.
    let toolCall = ToolCall(id: "c1", name: "web_fetch", argumentsJSON: "{}")
    let provider = RecordingStreamingProvider(rounds: [
      [
        .finished(
          ChatResponse(
            content: "aaaaaa",
            finishReason: "tool_calls",
            usage: nil,
            costFromProvider: nil,
            toolCalls: [toolCall]
          )
        )
      ],
      [
        .finished(
          ChatResponse(
            content: "bbbbbb",
            finishReason: "stop",
            usage: nil,
            costFromProvider: nil
          )
        )
      ],
    ])
    let runtime = makeRuntime(
      provider: provider,
      streamingEnabled: true,
      attemptOutputLimits: AttemptOutputLimits(maximumUTF8Bytes: 10, maximumGraphemes: 10),
      toolDispatcher: ScriptedDispatcher(respond: okOutcome(content: "page text"))
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 11,
      sessionId: 22,
      chatId: 33,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — round one charged six visible bytes plus two argument bytes; round two's six bytes
    // cross the shared cap. A fresh limiter per round would incorrectly complete.
    let degraded = try requireDegraded(outcome.result)
    #expect(degraded.kind == .providerUnavailable)
    #expect(outcome.attemptDiagnostics.failureCause == .localOutputLimit)
    #expect(
      outcome.attemptDiagnostics.outputCounts
        == AttemptOutputCounts(
          utf8Bytes: 14,
          graphemes: 14,
          limitExceeded: true
        )
    )
    #expect(await provider.requests.count == 2)
    #expect(await provider.requests.allSatisfy { $0.outputScope != nil })
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
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, _, _) = try requireCompleted(outcome.result)
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
      sessionHasPrivateData: false,
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

  @Test func theStreamToBufferedFallbackKeepsTheRoundOnOneCallIdentity() async throws {
    // given — the stream connect is refused, so the round is re-issued on the blocking path
    let provider = StreamingProvider(
      streamScript: .fail(
        ProviderFailure(cause: .connectFailed(message: "refused"), accounting: .notStarted)
      )
    )
    let runtime = makeRuntime(
      provider: provider,
      streamingEnabled: true,
      providerCallIDGenerator: SequentialCallIDGenerator()
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the round reached the provider twice but accounts as one call. Today the identity is
    // minted outside `roundTrip`, which owns the fallback, so this holds by scope; the assertion
    // guards the day against a future change that debits the retried attempt separately.
    #expect(await provider.streamCalls == 1)
    #expect(await provider.completeCalls == 1)
    let (_, usage, _) = try requireCompleted(outcome.result)
    #expect(usage.providerCallID == ProviderCallID(rawValue: "call-1"))
  }

  @Test func connectFailureFallsBackToBlockingCompleteOnce() async throws {
    // given
    let provider = StreamingProvider(
      streamScript: .fail(
        ProviderFailure(cause: .connectFailed(message: "refused"), accounting: .notStarted)
      )
    )
    let runtime = makeRuntime(provider: provider, streamingEnabled: true)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, _, _) = try requireCompleted(outcome.result)
    #expect(content == "blocking fallback")
    #expect(await provider.streamCalls == 1)
    #expect(await provider.completeCalls == 1)
  }

  @Test func disabledStreamingReattemptDoesNotSwitchTransportMode() async throws {
    // given — the caller owns any later attempt-level retry, so disabling the in-round reattempt
    // must leave a clean stream refusal as one provider send instead of changing transport mode
    let provider = StreamingProvider(
      streamScript: .fail(
        ProviderFailure(cause: .connectFailed(message: "refused"), accounting: .notStarted)
      )
    )
    let runtime = makeRuntime(
      provider: provider,
      streamingEnabled: true,
      streamingReattemptPolicy: .disabled
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, _) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(await provider.streamCalls == 1)
    #expect(await provider.completeCalls == 0)
    #expect(outcome.attemptDiagnostics.failureCause == .transportFailure)
  }

  @Test func expectedWireModelRejectsUnexpectedOutboundModelBeforeDispatch() async throws {
    // given
    let provider = StreamingProvider(streamScript: .events([]))
    let runtime = makeRuntime(
      provider: provider,
      model: "unexpected-wire-model",
      streamingEnabled: true,
      expectedWireModel: "gpt-5.6-sol"
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(outcome.attemptDiagnostics.failureCause == .modelIdentityMismatch)
    #expect(usage == nil)
    #expect(await provider.streamCalls == 0)
    #expect(
      outcome.attemptDiagnostics.modelObservations == [
        ModelRoundTripObservation(outboundModel: "unexpected-wire-model", terminalModel: nil)
      ]
    )
  }

  @Test func expectedWireModelRejectsUnexpectedTerminalModel() async throws {
    // given
    let provider = StreamingProvider(
      streamScript: .events([
        .finished(
          ChatResponse(
            content: "oversized",
            finishReason: "stop",
            usage: ChatUsage(promptTokens: 2, completionTokens: 1, totalTokens: 3),
            costFromProvider: nil,
            reportedModel: "different-model"
          )
        )
      ])
    )
    let runtime = makeRuntime(
      provider: provider,
      model: "gpt-5.6-sol",
      configuredReference: "openai-chatgpt/gpt-5.6-sol",
      costPolicy: .includedPlan,
      streamingEnabled: true,
      attemptOutputLimits: AttemptOutputLimits(maximumUTF8Bytes: 1, maximumGraphemes: 1),
      expectedWireModel: "gpt-5.6-sol"
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — identity is a batch-integrity invariant, so it wins even though terminal output also
    // crosses both local limits. Reordering the checks would misclassify this as localOutputLimit.
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(outcome.attemptDiagnostics.failureCause == .modelIdentityMismatch)
    #expect(usage != nil)
    #expect(
      outcome.attemptDiagnostics.modelObservations == [
        ModelRoundTripObservation(
          outboundModel: "gpt-5.6-sol",
          terminalModel: "different-model"
        )
      ]
    )
  }

  @Test func expectedWireModelAcceptsAbsentTerminalModel() async throws {
    // given
    let provider = RecordingStreamingProvider(rounds: [
      [
        .finished(
          ChatResponse(
            content: "validated",
            finishReason: "stop",
            usage: ChatUsage(promptTokens: 2, completionTokens: 1, totalTokens: 3),
            costFromProvider: nil,
            reportedModel: nil
          )
        )
      ]
    ])
    let runtime = makeRuntime(
      provider: provider,
      model: "gpt-5.6-sol",
      streamingEnabled: true,
      terminalValidationPolicy: .throughStreamEnd,
      expectedWireModel: "gpt-5.6-sol"
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let completed = try requireCompleted(outcome.result)
    #expect(completed.content == "validated")
    #expect(outcome.attemptDiagnostics.failureCause == nil)
    #expect(
      outcome.attemptDiagnostics.modelObservations == [
        ModelRoundTripObservation(outboundModel: "gpt-5.6-sol", terminalModel: nil)
      ]
    )
    let request = try #require(await provider.requests.first)
    #expect(request.terminalValidationPolicy == .throughStreamEnd)
  }

  @Test func preStreamRejectionFallsBackToBlockingCompleteOnce() async throws {
    // given — a clean 429 on the response head: nothing was generated, so one blocking
    // re-attempt is double-charge-safe; mid-stream failures keep degrading
    let provider = StreamingProvider(
      streamScript: .fail(
        ProviderFailure(
          cause: .rejected(status: 429, message: "rate limited"),
          accounting: .notStarted
        )
      )
    )
    let runtime = makeRuntime(provider: provider, streamingEnabled: true)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hi"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, _, _) = try requireCompleted(outcome.result)
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
          ChatResponse(
            content: "hello",
            finishReason: "stop",
            usage: ChatUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5),
            costFromProvider: 0.001
          )
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
      clock: ScriptedClock.compressed(parkingAt: .seconds(10))
    )

    // when
    let turnResult = startTurn {
      try await runtime.runTurn(
        runId: 11,
        sessionId: 22,
        chatId: 33,
        buildResult: self.singleUserBuildResult("hi"),
        sessionTainted: false,
        sessionHasPrivateData: false,
        todayTokens: 0,
        todayUSD: 0
      )
    }
    await drafts.waitUntilFirstSendBlocked()
    let outcome = await waitForTurnResult(turnResult)

    // then
    await drafts.release()
    let completed = try requireCompleted(try #require(outcome).result)
    #expect(completed.content == "hello")
    #expect(await provider.completeCalls == 0)
    #expect(await provider.streamCalls == 1)
  }

  @Test func postSendStreamFailureDegradesWithoutBlockingFallback() async throws {
    // given — a typed mid-stream transport drop may already have generated tokens, so a conservative
    // row is owed and the cause is not re-attempted on the buffered path
    let provider = StreamingProvider(
      streamScript: .fail(
        ProviderFailure(
          cause: .transportFailure(message: "drop"),
          accounting: .mayHaveStarted(observing: 0)
        )
      )
    )
    let runtime = makeRuntime(provider: provider, streamingEnabled: true)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hello world"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(try #require(usage).isEstimated)
    #expect(await provider.completeCalls == 0)
    #expect(outcome.attemptDiagnostics.failureCause == .transportFailure)
  }

  @Test func terminalStreamFailureDegradesWithoutDebit() async throws {
    // given — a recognized terminal head proves inference never started, so no tokens are owed
    let provider = StreamingProvider(
      streamScript: .fail(
        ProviderFailure(cause: .terminal(status: 400, message: "bad"), accounting: .notStarted)
      )
    )
    let runtime = makeRuntime(provider: provider, streamingEnabled: true)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hello world"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(usage == nil)
    #expect(await provider.completeCalls == 0)
    #expect(await provider.streamCalls == 1)
  }

  @Test func notStartedStreamFailureWritesNoUsageRow() async throws {
    // given — the streaming twin of the buffered no-row proof: the engine's budget-exhausted clean
    // 5xx, a retryable status thrown before the stream opened but tagged notStarted, so the model
    // was proven never asked and nothing is owed
    let store = RecordingUsageStore()
    let provider = StreamingProvider(
      streamScript: .fail(
        ProviderFailure(
          cause: .retryable(status: 503, message: "budget exhausted"),
          accounting: .notStarted
        )
      )
    )
    let runtime = makeRuntime(provider: provider, streamingEnabled: true, usageStore: store)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hello world"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the disposition, not the cause class, decides: no row is written on either transport
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(usage == nil)
    #expect(store.recorded.isEmpty)
    #expect(await provider.completeCalls == 0)
    #expect(await provider.streamCalls == 1)
  }

  @Test func mayHaveStartedStreamFailureKeepsTheObservedCount() async throws {
    // given — a streamed may-have-started whose observed lower bound overshoots the local output cap
    let observed = RunBudget.default.maxOutputTokens + 5_000
    let provider = StreamingProvider(
      streamScript: .fail(
        ProviderFailure(
          cause: .retryable(status: nil, message: "lost"),
          accounting: .mayHaveStarted(observing: observed)
        )
      )
    )
    let runtime = makeRuntime(provider: provider, streamingEnabled: true)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hello world"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the observed count survives the envelope: completion is n, not the capped 0
    let (_, usage) = try requireDegraded(outcome.result)
    let row = try #require(usage)
    #expect(row.isEstimated)
    #expect(row.completionTokens == observed)
    #expect(await provider.completeCalls == 0)
  }

  @Test func notStartedStreamCancellationWritesNoUsageRow() async throws {
    // given — a stream that reports a no-start cancellation as its terminal
    let store = RecordingUsageStore()
    let provider = StreamingProvider(streamScript: .reportsCancel(.notStarted))
    let runtime = makeRuntime(provider: provider, streamingEnabled: true, usageStore: store)

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hello world"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — a no-start cancel bills nothing, mirroring the raw-cancellation buffered case
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(usage == nil)
    #expect(store.recorded.isEmpty)
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
        sessionHasPrivateData: false,
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
    let runtime = makeRuntime(
      provider: provider,
      streamingEnabled: true,
      clock: ScriptedClock { _ in try? await Task.sleep(for: .milliseconds(1)) }
    )

    // when
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      buildResult: singleUserBuildResult("hello world"),
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(outcome.result)
    #expect(kind == .providerUnavailable)
    #expect(try #require(usage).isEstimated)
  }

  @Test func streamingDeadlineDegradesAndJoinsAStreamThatIgnoresCancellation() async throws {
    // given — an inference that acknowledges cancellation only once its gate opens
    let gate = NonCooperativeStreamGate()
    let provider = StreamingProvider(streamScript: .ignoresCancellation(gate))
    let runtime = makeRuntime(
      provider: provider,
      streamingEnabled: true,
      clock: ScriptedClock { _ in try? await Task.sleep(for: .milliseconds(1)) }
    )
    let flag = CompletionFlag()

    // when — the deadline wins while the inference is still parked
    let turnTask = Task {
      let outcome = try await runtime.runTurn(
        runId: 1,
        sessionId: 2,
        chatId: 3,
        buildResult: self.singleUserBuildResult("hello world"),
        sessionTainted: false,
        sessionHasPrivateData: false,
        todayTokens: 0,
        todayUSD: 0
      )
      await flag.markDone()
      return outcome
    }
    await gate.waitUntilStarted()
    // A yield lets a turn that abandoned its session surface, without a wall-clock window.
    await Task.yield()
    let doneWhileInferenceParked = await flag.done
    await gate.release()
    let outcome = try await turnTask.value

    // then — the turn owns the session, so it cannot report the deadline while the inference it
    // started is still running; once the inference lets go, the deadline degrades the turn
    #expect(doneWhileInferenceParked == false)
    let (kind, usage) = try requireDegraded(outcome.result)
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
