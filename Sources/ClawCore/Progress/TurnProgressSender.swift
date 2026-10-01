/// A transport-neutral frame collected without waiting for cosmetic network delivery.
package struct TurnProgressFrame: Sendable {
  package let markdown: String?
  package let typingAllowed: Bool

  package init(markdown: String?, typingAllowed: Bool) {
    self.markdown = markdown
    self.typingAllowed = typingAllowed
  }
}

package enum TurnProgressPacingMode: Sendable {
  case interactive
  case legacyProviderRound
}

/// Its caller owns `run`; this actor owns and joins every bounded draft send.
package actor TurnProgressSender {
  package static let probeInterval: Duration = .milliseconds(250)
  package static let minTicksBetweenDrafts = 5
  package static let sendDeadline: Duration = .seconds(3)
  private static let typingInterval: Duration = .seconds(4)
  private static let freshnessInterval: Duration = .seconds(25)

  private let target: DeliveryTarget
  private let draftID: Int64
  private let mode: TurnProgressPacingMode
  private let drafts: any RichDraftStreaming
  private let typing: any TypingIndicator
  private let clock: any Clock<Duration>
  private let frame: @Sendable () async -> TurnProgressFrame
  private var paused = false
  private var pauseRevision = 0
  private var draftEpoch = 0
  private var running = false
  private var activeDraft: Task<Bool, Never>?

  package init(
    target: DeliveryTarget,
    draftID: Int64,
    mode: TurnProgressPacingMode,
    drafts: any RichDraftStreaming,
    typing: any TypingIndicator,
    clock: any Clock<Duration>,
    frame: @escaping @Sendable () async -> TurnProgressFrame
  ) {
    self.target = target
    self.draftID = draftID
    self.mode = mode
    self.drafts = drafts
    self.typing = typing
    self.clock = clock
    self.frame = frame
  }

  package func run() async {
    guard !running else {
      return
    }
    running = true
    await run(clock: clock)
  }

  package func pauseDraftsAndAwait() async {
    pauseRevision += 1
    await setDraftsPaused(true, revision: pauseRevision)
  }

  package func resumeDrafts() {
    pauseRevision += 1
    if paused {
      draftEpoch += 1
    }
    paused = false
  }

  /// Revision order survives reentrant registry lease reconciliation.
  package func setDraftsPaused(_ paused: Bool, revision: Int) async {
    guard revision >= pauseRevision else {
      return
    }
    pauseRevision = revision
    if self.paused && !paused {
      draftEpoch += 1
    }
    self.paused = paused
    if paused, let activeDraft {
      activeDraft.cancel()
      _ = await activeDraft.value
    }
  }
}

// MARK: - Pacing

private extension TurnProgressSender {
  func run<C: Clock>(clock: C) async where C.Duration == Duration {
    var lastAttempt: C.Instant?
    var lastDelivery: C.Instant?
    var lastTyping: C.Instant?
    var lastMarkdown: String?
    var deliveredDrafts = 0
    var earlySecondAttempted = false
    var seenEpoch = draftEpoch

    while !Task.isCancelled {
      let latest = await frame()
      guard !Task.isCancelled else {
        return
      }
      if seenEpoch != draftEpoch {
        seenEpoch = draftEpoch
        lastMarkdown = nil
        lastDelivery = nil
      }
      let now = clock.now
      let earlySecond = deliveredDrafts == 1 && !earlySecondAttempted
      let minimum = Self.probeInterval * (earlySecond ? 1 : Self.minTicksBetweenDrafts)
      let due =
        lastAttempt.map {
          $0.duration(to: now) >= minimum
        } ?? true
      let refresh =
        mode == .interactive
        && (earlySecond
          || (lastDelivery.map {
            $0.duration(to: now) >= Self.freshnessInterval
          } ?? true))

      if !paused, due, let markdown = latest.markdown, !markdown.isEmpty,
         markdown != lastMarkdown || refresh
      {
        lastAttempt = now
        lastMarkdown = markdown
        if earlySecond {
          earlySecondAttempted = true
        }
        if await sendDraft(markdown) {
          deliveredDrafts += 1
          lastDelivery = clock.now
        }
      }

      guard !Task.isCancelled else {
        return
      }
      let stale =
        lastDelivery.map {
          mode == .interactive && $0.duration(to: clock.now) >= Self.freshnessInterval
        } ?? true
      let typingDue =
        lastTyping.map {
          $0.duration(to: clock.now) >= Self.typingInterval
        } ?? true
      // Collect again: approval can arrive while a draft request is in flight.
      let current = await frame()
      if current.typingAllowed, paused || stale, typingDue, !Task.isCancelled {
        await Self.sendBounded(timeout: Self.sendDeadline, clock: clock) { [typing, target] in
          await typing.sendTyping(
            chatID: target.chatID,
            messageThreadID: target.messageThreadID
          )
        }
        lastTyping = clock.now
      }
      do {
        try await clock.sleep(for: Self.probeInterval)
      } catch {
        return
      }
    }
  }

  func sendDraft(_ markdown: String) async -> Bool {
    let task = Task { [drafts, target, draftID, clock] in
      await Self.sendBounded(timeout: Self.sendDeadline, clock: clock) {
        await drafts.sendDraft(chatID: target.chatID, draftID: draftID, markdown: markdown)
      } ?? false
    }
    activeDraft = task
    let delivered = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    activeDraft = nil
    return delivered
  }
}

// MARK: - Bounded Ephemeral Send

extension TurnProgressSender {
  /// Owns both children and drains the cancelled loser. Sinks must observe cancellation to
  /// return promptly; a deadline never detaches a still-running send.
  @discardableResult
  package static func sendBounded<Value: Sendable>(
    timeout: Duration,
    clock: any Clock<Duration>,
    send: @escaping @Sendable () async -> Value
  ) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
      group.addTask {
        await send()
      }
      group.addTask {
        try? await clock.sleep(for: timeout)
        return nil
      }
      // swiftlint:disable:next redundant_nil_coalescing
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}
