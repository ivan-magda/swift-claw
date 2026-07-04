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
        try await sleep(.seconds(wallClockDeadlineSeconds))
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

  // MARK: - Load-bearing

  private func consumeStream(
    request: ChatRequest,
    snapshot: DraftSnapshot
  ) async throws -> ChatResponse {
    var content = ""
    var contentBytes = 0

    for try await event in provider.stream(request: request) {
      try Task.checkCancellation()
      switch event {
      case .delta(let delta):
        try append(delta: delta, to: &content, contentBytes: &contentBytes)
        // An empty accumulation (providers commonly open with an empty role-only delta) must
        // never surface as a blank draft bubble.
        if !content.isEmpty {
          await snapshot.publish(content)
        }
      case .finished(let finishReason, let usage, let providerCost, _):
        return ChatResponse(
          content: content,
          finishReason: finishReason,
          usage: usage,
          costFromProvider: providerCost
        )
      }
    }

    // A cancelled consumer ends iteration with nil instead of throwing, so re-check here or a
    // /stop-style cancel would surface the partial accumulation as a completed reply.
    try Task.checkCancellation()

    // EOF without a `.finished` event after valid deltas — treat as a complete reply.
    return ChatResponse(content: content, finishReason: nil, usage: nil, costFromProvider: nil)
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

  private func runDraftAndTypingLoop(
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
        try await sleep(Self.probeInterval)
      } catch {
        return
      }
      ticksSinceDraft += 1
      ticksSinceTyping += 1
    }
  }

  private func sendFinalDraft(_ content: String, chatId: Int64, draftId: Int64) async {
    guard !content.isEmpty, !Task.isCancelled else {
      return
    }
    await sendDraftBounded(content, chatId: chatId, draftId: draftId)
  }

  /// Awaits the sink but abandons it at `draftSendDeadline`: turn completion must never wedge on
  /// a stalled draft POST (spec §12 #14). Task groups always await their children, so the
  /// send/deadline pair is deliberately unstructured — first to finish wins, termination cancels
  /// both, and an abandoned send is harmless (the draft is ephemeral, best-effort UX).
  private func sendDraftBounded(_ markdown: String, chatId: Int64, draftId: Int64) async {
    let firstDone = AsyncStream<Void> { continuation in
      let sendTask = Task {
        await draftStreamer.sendDraft(chatId: chatId, draftId: draftId, markdown: markdown)
        continuation.yield()
        continuation.finish()
      }
      let deadlineTask = Task {
        try? await sleep(Self.draftSendDeadline)
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
