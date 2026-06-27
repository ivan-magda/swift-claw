import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

actor StreamingProvider: LLMProvider {
  enum StreamScript: Sendable {
    case events([StreamEvent])
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
  case result(TurnResult)
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

func startTurn(
  operation: @escaping @Sendable () async -> TurnResult
) -> TurnResultBox {
  let result = TurnResultBox()
  Task {
    await result.resolve(.result(await operation()))
  }
  return result
}

func waitForTurnResult(
  _ result: TurnResultBox,
  milliseconds: Int
) async -> TurnResult? {
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
  @Test func streamingTurnPublishesDraftsAndCompletesWithAccumulatedContent() async throws {
    // given
    let provider = StreamingProvider(
      streamScript: .events([
        .delta("he"),
        .delta("llo"),
        .finished(
          finishReason: "stop",
          usage: ChatUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5),
          providerCost: 0.001
        ),
      ])
    )
    let drafts = RecordingDrafts()
    let runtime = makeRuntime(provider: provider, drafts: drafts, streamingEnabled: true)

    // when
    let result = await runtime.runTurn(
      runId: 11,
      sessionId: 22,
      chatId: 33,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, usage) = try requireCompleted(result)
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

  @Test func streamingDisabledUsesBlockingCompletePath() async throws {
    // given
    let provider = StreamingProvider(streamScript: .events([.delta("ignored")]))
    let runtime = makeRuntime(provider: provider, streamingEnabled: false)

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, _) = try requireCompleted(result)
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
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(result)
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
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hi")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (content, _) = try requireCompleted(result)
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
          providerCost: 0.001
        ),
      ])
    )
    let drafts = BlockingDrafts()
    let runtime = makeRuntime(provider: provider, drafts: drafts, streamingEnabled: true)

    // when
    let turnResult = startTurn {
      await runtime.runTurn(
        runId: 11,
        sessionId: 22,
        chatId: 33,
        context: [ChatMessage(role: .user, content: "hi")],
        todayTokens: 0,
        todayUSD: 0
      )
    }
    await drafts.waitUntilFirstSendBlocked()
    let result = await waitForTurnResult(turnResult, milliseconds: 1_000)

    // then
    await drafts.release()
    let completed = try requireCompleted(try #require(result))
    #expect(completed.content == "hello")
    #expect(await provider.completeCalls == 0)
    #expect(await provider.streamCalls == 1)
  }

  @Test func postSendStreamFailureDegradesWithoutBlockingFallback() async throws {
    // given
    let provider = StreamingProvider(streamScript: .fail(.retryable(status: nil, message: "drop")))
    let runtime = makeRuntime(provider: provider, streamingEnabled: true)

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hello world")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(result)
    #expect(kind == .providerUnavailable)
    #expect(try #require(usage).isEstimated)
    #expect(await provider.completeCalls == 0)
  }

  @Test func terminalStreamFailureDegradesAndDebitsTheEstimate() async throws {
    // given
    let provider = StreamingProvider(streamScript: .fail(.terminal(status: 400, message: "bad")))
    let runtime = makeRuntime(provider: provider, streamingEnabled: true)

    // when
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hello world")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(result)
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
      let result = await runtime.runTurn(
        runId: 1,
        sessionId: 2,
        chatId: 3,
        context: [ChatMessage(role: .user, content: "hello world")],
        todayTokens: 0,
        todayUSD: 0
      )

      // then
      let (kind, usage) = try requireDegraded(result)
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
    let result = await runtime.runTurn(
      runId: 1,
      sessionId: 2,
      chatId: 3,
      context: [ChatMessage(role: .user, content: "hello world")],
      todayTokens: 0,
      todayUSD: 0
    )

    // then
    let (kind, usage) = try requireDegraded(result)
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
      await runtime.runTurn(
        runId: 1,
        sessionId: 2,
        chatId: 3,
        context: [ChatMessage(role: .user, content: "hello world")],
        todayTokens: 0,
        todayUSD: 0
      )
    }
    await gate.waitUntilStarted()
    let result = await waitForTurnResult(turnResult, milliseconds: 250)

    // then
    await gate.release()
    let (kind, usage) = try requireDegraded(try #require(result))
    #expect(kind == .providerUnavailable)
    #expect(try #require(usage).isEstimated)
  }

  private func oversizedStreamCases() -> [[StreamEvent]] {
    let chunk = String(repeating: "a", count: 1024)
    let manySmallDeltas = Array(
      repeating: StreamEvent.delta(chunk),
      count: (LLMStreamLimits.maxAccumulatedContentBytes / chunk.utf8.count) + 1
    )
    let singleOversizedDelta = [
      StreamEvent.delta(
        String(repeating: "a", count: LLMStreamLimits.maxAccumulatedContentBytes + 1)
      )
    ]
    return [manySmallDeltas, singleOversizedDelta]
  }
}
