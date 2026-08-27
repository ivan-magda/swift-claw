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

/// Races three children through the deadline coordinator: the SSE consumer (accumulates deltas and
/// publishes drafts), a draft/typing loop ("typing…" re-issued while waiting for the first token),
/// and the wall-clock deadline. The consumer and the deadline contend for the coordinator's lock; no
/// loser is discarded, and every child is drained before an outcome is read. The winning response is
/// finalized with one awaited, deadline-bounded full-content draft.
struct StreamingTurnRuntime: Sendable {
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
        await runDraftAndTypingLoop(chatId: chatId, draftId: draftId, snapshot: snapshot, box: box)
      }
    )

    switch outcome {
    case .response(let response):
      await sendFinalDraft(response.content, chatId: chatId, draftId: draftId)
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
      await sendFinalDraft(response.content, chatId: chatId, draftId: draftId)
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
    snapshot: DraftSnapshot,
    box: ProviderRaceBox
  ) async {
    var lastSeenVersion = 0
    var sentAnyDraft = false
    // Start both counters at their thresholds: typing fires on the first tick, and the first
    // draft goes out on the first tick that sees content.
    var ticksSinceDraft = Self.minTicksBetweenDrafts
    var ticksSinceTyping = Self.ticksBetweenTyping

    // Stops the moment the race is decided — a won provider or a won deadline — before cancellation
    // has to propagate, so the loop never draws a frame over a turn that has already resolved.
    while box.decided == nil, !Task.isCancelled {
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

  /// Awaits the sink but abandons it at `draftSendDeadline`: turn completion must never wedge on a
  /// stalled draft POST. The coordinator owns both children, so the abandoned send is cancelled and
  /// drained rather than left to outlive the turn — a structured replacement for the old detached
  /// send/deadline race.
  func sendDraftBounded(_ markdown: String, chatId: Int64, draftId: Int64) async {
    await ProviderDeadlineCoordinator.sendBounded(timeout: Self.draftSendDeadline, clock: clock) {
      await draftStreamer.sendDraft(chatId: chatId, draftId: draftId, markdown: markdown)
    }
  }
}
