/// A transport-neutral frame collected without waiting for cosmetic network delivery.
package struct TurnProgressFrame: Sendable {
  package let draft: RichDraft?
  package let typingAllowed: Bool

  package init(markdown: String?, typingAllowed: Bool) {
    self.draft = markdown.map(RichDraft.init(markdown:))
    self.typingAllowed = typingAllowed
  }

  package init(draft: RichDraft?, typingAllowed: Bool) {
    self.draft = draft
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
  private let stopControl: DraftStopControl
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
    stopControl: DraftStopControl,
    drafts: any RichDraftStreaming,
    typing: any TypingIndicator,
    clock: any Clock<Duration>,
    frame: @escaping @Sendable () async -> TurnProgressFrame
  ) {
    self.target = target
    self.draftID = draftID
    self.mode = mode
    self.stopControl = stopControl
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
    var seenDraftEpoch = draftEpoch

    while !Task.isCancelled {
      let latest = await frame()
      guard !Task.isCancelled else {
        return
      }

      if seenDraftEpoch != draftEpoch {
        seenDraftEpoch = draftEpoch
        lastMarkdown = nil
        lastDelivery = nil
      }

      let now = clock.now
      let isEarlySecondAttempt = deliveredDrafts == 1 && !earlySecondAttempted
      let ticksBetweenAttempts = isEarlySecondAttempt ? 1 : Self.minTicksBetweenDrafts
      let minimumDraftInterval = Self.probeInterval * ticksBetweenAttempts

      let draftDue =
        if let lastAttempt {
          lastAttempt.duration(to: now) >= minimumDraftInterval
        } else {
          true
        }

      let deliveryNeedsRefresh =
        if let lastDelivery {
          lastDelivery.duration(to: now) >= Self.freshnessInterval
        } else {
          true
        }

      let shouldRefresh = mode == .interactive && (isEarlySecondAttempt || deliveryNeedsRefresh)
      let canSendDraft = !paused && draftDue && latest.draft?.markdown.isEmpty == false
      let hasDraftUpdate = latest.draft?.markdown != lastMarkdown || shouldRefresh

      if canSendDraft, hasDraftUpdate, let draft = latest.draft {
        lastAttempt = now
        lastMarkdown = draft.markdown

        if isEarlySecondAttempt {
          earlySecondAttempted = true
        }

        if await sendDraft(draft) {
          deliveredDrafts += 1
          lastDelivery = clock.now
        }
      }

      guard !Task.isCancelled else {
        return
      }

      let draftIsStale =
        if let lastDelivery {
          mode == .interactive && lastDelivery.duration(to: clock.now) >= Self.freshnessInterval
        } else {
          true
        }
      let typingDue =
        if let lastTyping {
          lastTyping.duration(to: clock.now) >= Self.typingInterval
        } else {
          true
        }

      // Collect again: approval can arrive while a draft request is in flight.
      let current = await frame()
      if current.typingAllowed, paused || draftIsStale, typingDue, !Task.isCancelled {
        await Self.sendBounded(
          timeout: Self.sendDeadline,
          clock: clock
        ) { [typing, target] in
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

  func sendDraft(_ draft: RichDraft) async -> Bool {
    let task = Task { [drafts, target, draftID, clock, stopControl] in
      let deliveryResult = await Self.sendBounded(
        timeout: Self.sendDeadline,
        clock: clock
      ) {
        await drafts.sendDraft(
          chatID: target.chatID,
          draftID: draftID,
          draft: draft,
          stopControl: stopControl
        )
      }
      return deliveryResult ?? false
    }
    activeDraft = task

    let delivered = await withTaskCancellationHandler(
      operation: {
        await task.value
      },
      onCancel: {
        task.cancel()
      }
    )
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
