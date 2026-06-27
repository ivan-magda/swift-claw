import ClawCore
import Foundation

private actor StreamingDraftBuffer {
  enum Item: Sendable, Equatable {
    case update(String)
    case final(String)
  }

  private var latest: String?
  private var final: String?
  private var closed = false
  private var finalSent = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func publish(_ markdown: String) {
    guard !closed, final == nil else {
      return
    }
    latest = markdown
    wakeWaiters()
  }

  func publishFinal(_ markdown: String) {
    guard !closed else {
      return
    }

    latest = nil
    final = markdown

    wakeWaiters()
  }

  func close() {
    closed = true
    wakeWaiters()
  }

  func next() async -> Item? {
    while latest == nil && final == nil && !closed {
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }

    if let markdown = latest {
      latest = nil
      return .update(markdown)
    }
    if let markdown = final {
      final = nil
      return .final(markdown)
    }

    return nil
  }

  func takeFinal() -> String? {
    guard let markdown = final else {
      return nil
    }
    final = nil
    return markdown
  }

  func markFinalSent() {
    finalSent = true
  }

  func didSendFinal() -> Bool {
    finalSent
  }

  private func wakeWaiters() {
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
  }
}

struct StreamingTurnRuntime: Sendable {
  private struct AccumulatedStreamContentTooLarge: Error {}

  private struct FinishedResponse: Sendable {
    let content: String
    let finishReason: String?
    let usage: ChatUsage?
    let providerCost: Double?
  }

  private static let draftThrottleProbeInterval: Duration = .milliseconds(10)
  private static let draftThrottleProbeAttempts = 120
  private static let finalDraftDrainAttempts = 25
  private static let finalDraftDrainInterval: Duration = .milliseconds(10)

  private let provider: any LLMProvider
  private let typingIndicator: any TypingIndicator
  private let draftStreamer: any RichDraftStreaming
  private let wallClockDeadlineSeconds: Int
  private let sleep: @Sendable (Duration) async throws -> Void

  init(
    provider: any LLMProvider,
    typingIndicator: any TypingIndicator,
    draftStreamer: any RichDraftStreaming,
    wallClockDeadlineSeconds: Int,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.provider = provider
    self.typingIndicator = typingIndicator
    self.draftStreamer = draftStreamer
    self.wallClockDeadlineSeconds = wallClockDeadlineSeconds
    self.sleep = sleep
  }

  func run(
    chatId: Int64,
    draftId: Int64,
    request: ChatRequest
  ) async throws -> ChatResponse {
    let draftBuffer = StreamingDraftBuffer()
    let responseStream = makeStreamingResponseStream(
      request: request,
      chatId: chatId,
      draftBuffer: draftBuffer
    )
    let draftTask = makeDraftSenderTask(chatId: chatId, draftId: draftId, draftBuffer: draftBuffer)

    defer {
      draftTask.cancel()
      Task { await draftBuffer.close() }
    }

    return try await withThrowingTaskGroup(of: ChatResponse.self) { group in
      defer { group.cancelAll() }

      group.addTask {
        var iterator = responseStream.makeAsyncIterator()
        guard let response = try await iterator.next() else {
          throw AgentRuntime.DeadlineExceeded()
        }
        return response
      }
      group.addTask {
        try await sleep(.seconds(wallClockDeadlineSeconds))
        throw AgentRuntime.DeadlineExceeded()
      }

      guard let response = try await group.next() else {
        throw AgentRuntime.DeadlineExceeded()
      }
      if !response.content.isEmpty {
        await drainFinalDraftIfPossible(draftBuffer)
      }

      return response
    }
  }

  private func makeStreamingResponseStream(
    request: ChatRequest,
    chatId: Int64,
    draftBuffer: StreamingDraftBuffer
  ) -> AsyncThrowingStream<ChatResponse, Error> {
    AsyncThrowingStream { continuation in
      let responseTask = Task {
        await consumeStream(
          request: request,
          chatId: chatId,
          draftBuffer: draftBuffer,
          continuation
        )
      }
      continuation.onTermination = { _ in
        responseTask.cancel()
        Task { await draftBuffer.close() }
      }
    }
  }

  private func consumeStream(
    request: ChatRequest,
    chatId: Int64,
    draftBuffer: StreamingDraftBuffer,
    _ continuation: AsyncThrowingStream<ChatResponse, Error>.Continuation
  ) async {
    await typingIndicator.sendTyping(chatId: chatId)
    var content = ""
    var contentBytes = 0

    do {
      for try await event in provider.stream(request: request) {
        try Task.checkCancellation()
        switch event {
        case .delta(let delta):
          try append(delta: delta, to: &content, contentBytes: &contentBytes)
          await draftBuffer.publish(content)
        case .finished(let finishReason, let usage, let providerCost):
          await finishStreamingResponse(
            FinishedResponse(
              content: content,
              finishReason: finishReason,
              usage: usage,
              providerCost: providerCost
            ),
            draftBuffer: draftBuffer,
            continuation
          )
          return
        }
      }

      await finishStreamingResponse(
        FinishedResponse(
          content: content,
          finishReason: nil,
          usage: nil,
          providerCost: nil
        ),
        draftBuffer: draftBuffer,
        continuation
      )
    } catch {
      await draftBuffer.close()
      continuation.finish(throwing: error)
    }
  }

  private func append(
    delta: String,
    to content: inout String,
    contentBytes: inout Int
  ) throws {
    let deltaBytes = delta.utf8.count
    guard deltaBytes <= LLMStreamLimits.maxAccumulatedContentBytes - contentBytes else {
      throw AccumulatedStreamContentTooLarge()
    }

    contentBytes += deltaBytes
    content.append(delta)
  }

  private func finishStreamingResponse(
    _ response: FinishedResponse,
    draftBuffer: StreamingDraftBuffer,
    _ continuation: AsyncThrowingStream<ChatResponse, Error>.Continuation
  ) async {
    if !response.content.isEmpty {
      await draftBuffer.publishFinal(response.content)
    } else {
      await draftBuffer.close()
    }
    continuation.yield(
      ChatResponse(
        content: response.content,
        finishReason: response.finishReason,
        usage: response.usage,
        costFromProvider: response.providerCost
      )
    )
    continuation.finish()
  }

  private func makeDraftSenderTask(
    chatId: Int64,
    draftId: Int64,
    draftBuffer: StreamingDraftBuffer
  ) -> Task<Void, Never> {
    Task {
      var sentOnce = false
      while !Task.isCancelled {
        guard let item = await draftBuffer.next() else {
          return
        }

        switch item {
        case .update(let markdown):
          if sentOnce {
            if let finalMarkdown = await draftBuffer.takeFinal() {
              await sendFinalDraft(finalMarkdown, chatId: chatId, draftId: draftId, draftBuffer)
              return
            }
            if let finalMarkdown = await waitForFinalDuringDraftThrottle(draftBuffer) {
              await sendFinalDraft(finalMarkdown, chatId: chatId, draftId: draftId, draftBuffer)
              return
            }
          }

          guard !Task.isCancelled else {
            return
          }

          await draftStreamer.sendDraft(chatId: chatId, draftId: draftId, markdown: markdown)
          sentOnce = true
        case .final(let markdown):
          await sendFinalDraft(markdown, chatId: chatId, draftId: draftId, draftBuffer)
          return
        }
      }
    }
  }

  private func waitForFinalDuringDraftThrottle(
    _ draftBuffer: StreamingDraftBuffer
  ) async -> String? {
    for _ in 0..<Self.draftThrottleProbeAttempts {
      do {
        try await sleep(Self.draftThrottleProbeInterval)
      } catch {
        return nil
      }
      if let finalMarkdown = await draftBuffer.takeFinal() {
        return finalMarkdown
      }
    }
    return nil
  }

  private func sendFinalDraft(
    _ markdown: String,
    chatId: Int64,
    draftId: Int64,
    _ draftBuffer: StreamingDraftBuffer
  ) async {
    guard !Task.isCancelled else {
      return
    }
    await draftStreamer.sendDraft(chatId: chatId, draftId: draftId, markdown: markdown)
    await draftBuffer.markFinalSent()
  }

  private func drainFinalDraftIfPossible(_ draftBuffer: StreamingDraftBuffer) async {
    for _ in 0..<Self.finalDraftDrainAttempts {
      if await draftBuffer.didSendFinal() {
        return
      }
      do {
        try await sleep(Self.finalDraftDrainInterval)
      } catch {
        return
      }
    }
  }
}
