import ClawCore
import Foundation

/// Latest-value slot between the SSE consumer and the draft/typing child. Overwrites coalesce —
/// a slow sender only ever sees the newest accumulation.
private actor DraftSnapshot {
  private var content = ""

  func publish(_ markdown: String) {
    content = markdown
  }

  func latest() -> String? {
    content.isEmpty ? nil : content
  }
}

/// Races three children through the deadline coordinator: the SSE consumer (accumulates deltas and
/// publishes drafts), a draft/typing loop ("typing…" re-issued while waiting for the first token),
/// and the wall-clock deadline. The consumer and the deadline contend for the coordinator's lock; no
/// loser is discarded, and every child is drained before an outcome is read. The winning response is
/// finalized with one awaited, deadline-bounded full-content draft.
struct StreamingTurnRuntime: Sendable {
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

  func run(target: TurnProgressTarget, request: ChatRequest) async throws -> ChatResponse {
    let snapshot = DraftSnapshot()
    // Built before the race children start, so the runtime holds the cancel-and-join handle before
    // any authorization or network work can race the deadline.
    let stream = provider.stream(request: request)

    let outcome = await ProviderDeadlineCoordinator.raceStreaming(
      stream: stream,
      deadlineSeconds: wallClockDeadlineSeconds,
      clock: clock,
      consume: { stream, box in
        await consumeStream(stream, snapshot: snapshot, box: box)
      },
      auxiliary: { box in
        await runDraftAndTypingLoop(target: target, snapshot: snapshot, box: box)
      }
    )

    switch outcome {
    case .response(let response):
      await sendFinalDraft(response.content, target: target)
      return response
    case .failed(let error):
      throw error
    case .timedOut(.notStarted):
      throw ProviderNoStartDeadline()
    case .timedOut(.mayHaveStarted(let observedCompletionTokens)):
      // The interrupted attempt may already owe tokens, so the typed marker carries the observed
      // lower bound for the runtime's conservative row.
      throw ProviderInferenceCancellation(observing: observedCompletionTokens)
    case .timedOut(.completed(let response)):
      // A completed stream is surfaced as `.response` above; kept exhaustive for the enum.
      await sendFinalDraft(response.content, target: target)
      return response
    }
  }
}

// MARK: - Stream Consumption

private extension StreamingTurnRuntime {
  /// Iterates the stream, accumulating deltas and publishing drafts, and reports what it saw as a
  /// value — never a throw across the coordinator's group. On the terminal event it claims the race
  /// for the provider; the authoritative reply, content included, is read from the stream's own join,
  /// so the accumulation here feeds live drafts and the overflow check only, never the final reply. A
  /// cut iteration and a failed terminal both defer to that join, which carries the disposition; an
  /// overrun is flagged so the coordinator can refuse it locally.
  func consumeStream(
    _ stream: LLMEventStream,
    snapshot: DraftSnapshot,
    box: ProviderRaceBox
  ) async -> StreamConsumerOutcome {
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
        case .progress:
          continue
        case .finished:
          _ = box.claim(.provider)
          return .completed
        }
      }
      return .cut
    } catch is AccumulatedStreamContentTooLarge {
      return .overflowed
    } catch {
      // A cancelled consumer ends here (checkCancellation), and a failed terminal throws its cause.
      // Either way the authoritative outcome is the stream's own termination, read by the coordinator
      // — a cut reply is never surfaced as a whole one.
      return .cut
    }
  }

  func append(delta: String, to content: inout String, contentBytes: inout Int) throws {
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
    target: TurnProgressTarget,
    snapshot: DraftSnapshot,
    box: ProviderRaceBox
  ) async {
    let sender = TurnProgressSender(
      target: DeliveryTarget(chatID: target.chatID, messageThreadID: target.threadID),
      draftID: target.draftID,
      mode: .legacyProviderRound,
      drafts: draftStreamer,
      typing: typingIndicator,
      clock: clock
    ) {
      guard box.decided == nil else {
        return TurnProgressFrame(markdown: nil, typingAllowed: false)
      }
      return TurnProgressFrame(markdown: await snapshot.latest(), typingAllowed: true)
    }
    await sender.run()
  }

  func sendFinalDraft(_ content: String, target: TurnProgressTarget) async {
    guard !content.isEmpty, !Task.isCancelled else {
      return
    }
    _ = await sendDraftBounded(content, target: target)
  }

  /// The shared bounded sender cancels and drains a stalled draft before this turn returns.
  func sendDraftBounded(_ markdown: String, target: TurnProgressTarget) async -> Bool {
    let delivered = await TurnProgressSender.sendBounded(
      timeout: TurnProgressSender.sendDeadline,
      clock: clock
    ) {
      await draftStreamer.sendDraft(
        chatID: target.chatID,
        draftID: target.draftID,
        markdown: markdown
      )
    }
    return delivered ?? false
  }
}
