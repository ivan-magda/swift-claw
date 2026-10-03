import ClawCore

/// One active run's bounded display state and owned cosmetic sender.
public actor TurnPresentation {
  private var state: TurnProgressState
  private let renderer: any TurnProgressRendering
  private let draftsEnabled: Bool
  private let elapsed: @Sendable () -> Duration
  private let target: DeliveryTarget
  private let draftID: Int64
  private let drafts: any RichDraftStreaming
  private let typing: any TypingIndicator
  private let clock: any Clock<Duration>
  private var terminal = false
  private var paused = true
  private var pauseRevision = 0
  private var sender: TurnProgressSender?
  private var senderTask: Task<Void, Never>?

  init(
    target: DeliveryTarget,
    draftID: Int64,
    draftsEnabled: Bool,
    progressEnabled: Bool,
    resumed: Bool,
    renderer: any TurnProgressRendering,
    drafts: any RichDraftStreaming,
    typing: any TypingIndicator,
    secretValues: [String],
    clock: any Clock<Duration>
  ) {
    self.target = target
    self.draftID = draftID
    self.draftsEnabled = draftsEnabled
    self.renderer = renderer
    self.drafts = drafts
    self.typing = typing
    self.clock = clock
    elapsed = Self.elapsed(on: clock)
    state = TurnProgressState(
      showsProgress: progressEnabled,
      resumed: resumed,
      secretValues: secretValues
    )
  }

  public func publish(_ event: TurnProgressEvent) {
    guard !terminal else {
      return
    }
    state.apply(event)
  }

  public func closeAndAwait() async {
    terminal = true
    senderTask?.cancel()
    // Retain the handle: reentrant and repeated callers must join the same completion.
    await senderTask?.value
  }

  func start() {
    guard !terminal, senderTask == nil else {
      return
    }

    let sender = TurnProgressSender(
      target: target,
      draftID: draftID,
      mode: .interactive,
      stopControl: .dismissesDraft,
      drafts: drafts,
      typing: typing,
      clock: clock
    ) { [weak self] in
      await self?.frame() ?? TurnProgressFrame(markdown: nil, typingAllowed: false)
    }
    self.sender = sender

    senderTask = Task {
      await sender.run()
    }
  }

  func setDraftsPaused(_ paused: Bool, revision: Int) async {
    guard revision >= pauseRevision else {
      return
    }

    pauseRevision = revision
    self.paused = paused

    await sender?.setDraftsPaused(paused, revision: revision)
  }
}

// MARK: - Frame Collection

private extension TurnPresentation {
  func frame() -> TurnProgressFrame {
    guard !terminal else {
      return TurnProgressFrame(markdown: nil, typingAllowed: false)
    }

    let snapshot = state.snapshot(
      elapsedSeconds: Int(elapsed().components.seconds)
    )

    return TurnProgressFrame(
      draft: draftsEnabled && !paused ? renderer.renderDraft(snapshot) : nil,
      typingAllowed: snapshot.phase != .approval
    )
  }

  static func elapsed<C: Clock>(
    on clock: C
  ) -> @Sendable () -> Duration where C.Duration == Duration {
    let start = clock.now
    return {
      start.duration(to: clock.now)
    }
  }
}
