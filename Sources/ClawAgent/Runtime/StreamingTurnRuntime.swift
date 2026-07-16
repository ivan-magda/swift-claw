import ClawCore
import Foundation

/// Latest-value slot between the SSE consumer and the draft/typing child. Overwrites coalesce —
/// a slow sender only ever sees the newest accumulation — and the version lets it skip ticks
/// with nothing new.
private actor DraftSnapshot {
  private var content = ""
  private var version = 0

  func publish(_ markdown: String) {
    content = markdown
    version += 1
  }

  func newer(than seenVersion: Int) -> (content: String, version: Int)? {
    guard version > seenVersion else {
      return nil
    }
    return (content, version)
  }
}

/// Races three children: the SSE consumer (accumulates deltas, returns the response), a
/// draft/typing loop (throttled rich-draft frames once content exists, "typing…" re-issued
/// while waiting for the first token), and the wall-clock deadline. The winning response is
/// finalized with one awaited, deadline-bounded full-content draft.
struct StreamingTurnRuntime: Sendable {
  private struct AccumulatedStreamContentTooLarge: Error {}

  /// Probe cadence for the draft/typing child. Sends are rate-limited in ticks so the wire
  /// cadence stays near the spec's ~1.2s min-interval while the first frame still goes out on
  /// the next probe after content appears.
  private static let probeInterval: Duration = .milliseconds(250)
  private static let minTicksBetweenDrafts = 5
  /// Telegram's typing action auto-expires after ~5s; re-issue just under that window,
  /// mirroring `TypingTurnRuntime`.
  private static let ticksBetweenTyping = 16
  /// Hard bound on any one draft send: a hung sink is abandoned, never blocking the lane.
  private static let draftSendDeadline: Duration = .seconds(3)

  private let provider: any LLMProvider
  private let typingIndicator: any TypingIndicator
  private let draftStreamer: any RichDraftStreaming

  private let wallClockDeadlineSeconds: Int

  private let clock: any Clock<Duration>

  init(
    provider: any LLMProvider,
    typingIndicator: any TypingIndicator,
    draftStreamer: any RichDraftStreaming,
    wallClockDeadlineSeconds: Int,
    clock: any Clock<Duration>
  ) {
    self.provider = provider
    self.typingIndicator = typingIndicator
    self.draftStreamer = draftStreamer

    self.wallClockDeadlineSeconds = wallClockDeadlineSeconds

    self.clock = clock
  }

  func run(
    chatId: Int64,
    draftId: Int64,
    request: ChatRequest
  ) async throws -> ChatResponse {
    let snapshot = DraftSnapshot()

    return try await withThrowingTaskGroup(of: ChatResponse?.self) { group in
      defer { group.cancelAll() }

      group.addTask {
        try await consumeStream(request: request, snapshot: snapshot)
      }
      group.addTask {
        await runDraftAndTypingLoop(chatId: chatId, draftId: draftId, snapshot: snapshot)
        return nil
      }
      group.addTask {
        try await clock.sleep(for: .seconds(wallClockDeadlineSeconds))
        throw AgentRuntime.DeadlineExceeded()
      }

      for try await outcome in group {
        guard let response = outcome else {
          continue
        }
        group.cancelAll()
        await sendFinalDraft(response.content, chatId: chatId, draftId: draftId)
        return response
      }

      throw AgentRuntime.DeadlineExceeded()
    }
  }
}

// MARK: - Stream Consumption

private extension StreamingTurnRuntime {
  /// Joins the session on every way out. The session owns the inference and, through it, the HTTP
  /// transfer, so returning without joining would leave both running behind a finished turn.
  func consumeStream(
    request: ChatRequest,
    snapshot: DraftSnapshot
  ) async throws -> ChatResponse {
    let stream = provider.stream(request: request)
    do {
      let response = try await accumulate(from: stream, snapshot: snapshot)
      _ = await stream.awaitTermination()
      return response
    } catch {
      _ = await stream.cancelAndAwait()
      throw error
    }
  }

  func accumulate(
    from stream: LLMEventStream,
    snapshot: DraftSnapshot
  ) async throws -> ChatResponse {
    var content = ""
    var contentBytes = 0

    do {
      for try await event in stream {
        try Task.checkCancellation()
        switch event {
        case .delta(let delta):
          try append(delta: delta, to: &content, contentBytes: &contentBytes)
          // An empty accumulation (providers commonly open with an empty role-only delta) must
          // never surface as a blank draft bubble.
          if !content.isEmpty {
            await snapshot.publish(content)
          }
        case .finished(let response):
          // The accumulation, not the terminal's own copy, is what the drafts have been showing;
          // taking the reply from anywhere else would let the final frame disagree with them.
          return ChatResponse(
            content: content,
            finishReason: response.finishReason,
            usage: response.usage,
            costFromProvider: response.costFromProvider,
            toolCalls: response.toolCalls,
            providerState: response.providerState
          )
        }
      }
    } catch let failure as ProviderFailure {
      // The turn's one-time stream-to-buffered fallback turns on the typed cause, so hand that cause
      // on rather than an envelope no caller upstream matches.
      throw failure.cause
    }

    // A cancelled consumer ends iteration with nil instead of throwing. Rather than re-check and
    // surface a bare cancel here — which would drop the accounting the terminal carries and let a
    // partial accumulation read as a completed reply — the join below decides: a dry queue means the
    // reply is not whole, and the terminal says why, including whether the interrupted attempt may
    // already owe tokens.
    throw Self.error(for: await stream.awaitTermination())
  }

  /// A terminal that reached here is never `.completed`: that case returns from the loop above with
  /// its reserved event. Cancellation carries its accounting disposition on: a may-have-started
  /// interruption becomes the typed marker so the runtime records conservative usage, while a
  /// no-start one stays a plain cancel that bills nothing. The bare `failure.cause` is deliberate —
  /// the one-time stream-to-buffered fallback matches on the typed cause, and a wrapper no upstream
  /// caller unwraps would defeat it.
  static func error(for termination: LLMStreamTermination) -> any Error {
    switch termination {
    case .failed(let failure):
      return failure.cause
    case .cancelled(.mayHaveStarted(let observedCompletionTokens)):
      return ProviderInferenceCancellation(observing: observedCompletionTokens)
    case .cancelled(.notStarted):
      return CancellationError()
    case .completed:
      return ProviderError.retryable(
        status: nil,
        message: "streamed reply ended without a terminal"
      )
    }
  }

  func append(
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
}

// MARK: - Draft And Typing Loop

private extension StreamingTurnRuntime {
  func runDraftAndTypingLoop(
    chatId: Int64,
    draftId: Int64,
    snapshot: DraftSnapshot
  ) async {
    var lastSeenVersion = 0
    var sentAnyDraft = false
    // Start both counters at their thresholds: typing fires on the first tick, and the first
    // draft goes out on the first tick that sees content.
    var ticksSinceDraft = Self.minTicksBetweenDrafts
    var ticksSinceTyping = Self.ticksBetweenTyping

    while !Task.isCancelled {
      let latest = await snapshot.newer(than: lastSeenVersion)
      let mayDraft = !sentAnyDraft || ticksSinceDraft >= Self.minTicksBetweenDrafts

      if let latest, mayDraft {
        lastSeenVersion = latest.version
        await sendDraftBounded(latest.content, chatId: chatId, draftId: draftId)
        sentAnyDraft = true
        ticksSinceDraft = 0
      } else if !sentAnyDraft, ticksSinceTyping >= Self.ticksBetweenTyping {
        // Before the first visible frame the draft bubble doesn't exist yet, so the typing
        // action is the only progress signal; once a draft is out it takes over (~30s TTL).
        await typingIndicator.sendTyping(chatId: chatId)
        ticksSinceTyping = 0
      }

      do {
        try await clock.sleep(for: Self.probeInterval)
      } catch {
        return
      }
      ticksSinceDraft += 1
      ticksSinceTyping += 1
    }
  }

  func sendFinalDraft(_ content: String, chatId: Int64, draftId: Int64) async {
    guard !content.isEmpty, !Task.isCancelled else {
      return
    }
    await sendDraftBounded(content, chatId: chatId, draftId: draftId)
  }

  /// Awaits the sink but abandons it at `draftSendDeadline`: turn completion must never wedge on
  /// a stalled draft POST. Task groups always await their children, so the
  /// send/deadline pair is deliberately unstructured — first to finish wins, termination cancels
  /// both, and an abandoned send is harmless (the draft is ephemeral, best-effort UX).
  func sendDraftBounded(_ markdown: String, chatId: Int64, draftId: Int64) async {
    let firstDone = AsyncStream<Void> { continuation in
      let sendTask = Task {
        await draftStreamer.sendDraft(chatId: chatId, draftId: draftId, markdown: markdown)
        continuation.yield()
        continuation.finish()
      }
      let deadlineTask = Task {
        try? await clock.sleep(for: Self.draftSendDeadline)
        continuation.yield()
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in
        sendTask.cancel()
        deadlineTask.cancel()
      }
    }

    for await _ in firstDone {
      break
    }
  }
}
