import ClawAgent
import ClawCore
import Foundation

/// Presentation admission and delivery exclusion; session lanes still own execution order.
public actor TurnPresentationRegistry {
  struct Entry {
    let scope: TurnScope
    let presentation: TurnPresentation
    let reporter: TurnProgressReporter
    var pendingStep: TurnToolStepID?
  }

  private let streamingEnabled: Bool
  private let progressEnabled: Bool
  private let renderer: any TurnProgressRendering
  private let drafts: any RichDraftStreaming
  private let typing: any TypingIndicator
  private let outbox: any OutboxStore
  private let secretValues: [String]
  private let clock: any Clock<Duration>
  private var entries: [Int64: Entry] = [:]
  private var leases: [UUID: Int64] = [:]
  private var revision = 0
  private var stopped = false

  public init(
    streamingEnabled: Bool,
    progressEnabled: Bool,
    renderer: any TurnProgressRendering,
    drafts: any RichDraftStreaming,
    typing: any TypingIndicator,
    outbox: any OutboxStore,
    secretValues: [String],
    clock: any Clock<Duration>
  ) {
    self.streamingEnabled = streamingEnabled
    self.progressEnabled = progressEnabled
    self.renderer = renderer
    self.drafts = drafts
    self.typing = typing
    self.outbox = outbox
    self.secretValues = secretValues
    self.clock = clock
  }

  public func begin(scope: TurnScope, resumed: Bool = false) async -> TurnProgressReporter? {
    guard !Task.isCancelled, !stopped, scope.origin == .interactive else {
      return nil
    }
    if let entry = entries[scope.runID] {
      return entry.reporter
    }
    let presentation = TurnPresentation(
      target: DeliveryTarget(chatID: scope.chatID, messageThreadID: scope.threadID),
      draftID: scope.runID,
      draftsEnabled: streamingEnabled && scope.mode == .direct,
      progressEnabled: progressEnabled,
      resumed: resumed,
      renderer: renderer,
      drafts: drafts,
      typing: typing,
      secretValues: secretValues,
      clock: clock
    )
    let reporter = TurnProgressReporter(explanationsEnabled: progressEnabled) { [weak self] event in
      await self?.publish(event, runID: scope.runID)
    }
    let entry = Entry(scope: scope, presentation: presentation, reporter: reporter)
    // No suspension between cancellation/shutdown admission and registration.
    entries[scope.runID] = entry
    await presentation.start()
    await reconcile(entry)
    return reporter
  }

  public func waitingForApproval(runID: Int64) async {
    guard let entry = entries[runID], let id = entry.pendingStep else {
      return
    }
    await entry.presentation.publish(.waitingForApproval(id: id))
  }

  public func approvalProgress(runID: Int64, toolCallID: String) -> ToolProgressReporter? {
    guard let entry = entries[runID] else {
      return nil
    }
    let id =
      entry.pendingStep
      ?? TurnToolStepID(
        providerCallID: UUID().uuidString,
        toolCallID: toolCallID
      )
    entries[runID]?.pendingStep = id
    return ToolProgressReporter(
      identify: { tool, preview in
        await entry.reporter.publish(.toolStarted(id: id, tool: tool, preview: preview))
      },
      publish: { state in
        await entry.reporter.publish(.toolState(id: id, state: state))
      }
    )
  }

  public func close(runID: Int64) async {
    guard let entry = entries[runID] else {
      return
    }
    await entry.presentation.closeAndAwait()
    if entries[runID]?.presentation === entry.presentation {
      entries.removeValue(forKey: runID)
    }
  }

  public func close(sessionID: Int64) async {
    let matches = entries.values.filter {
      $0.scope.sessionID == sessionID
    }
    for entry in matches {
      await close(runID: entry.scope.runID)
    }
  }

  public func shutdown() async {
    stopped = true
    let runIDs = Array(entries.keys)
    for runID in runIDs {
      await close(runID: runID)
    }
  }

  public func beginDelivery(to target: DeliveryTarget) async -> UUID {
    let lease = UUID()
    leases[lease] = target.chatID
    let matches = entries.values.filter {
      $0.scope.chatID == target.chatID
    }
    for entry in matches {
      await reconcile(entry)
    }
    return lease
  }

  public func endDelivery(_ leaseID: UUID) async {
    guard let chatID = leases.removeValue(forKey: leaseID) else {
      return
    }
    let matches = entries.values.filter {
      $0.scope.chatID == chatID
    }
    for entry in matches {
      await reconcile(entry)
    }
  }
}

// MARK: - Delivery Holds

private extension TurnPresentationRegistry {
  func reconcile(_ entry: Entry) async {
    revision += 1
    let held = holdsDrafts(for: entry.scope)
    await entry.presentation.setDraftsPaused(held, revision: revision)
  }

  func holdsDrafts(for scope: TurnScope) -> Bool {
    if leases.values.contains(scope.chatID) {
      return true
    }
    do {
      return try outbox.pendingOutbound().contains {
        $0.chatID == scope.chatID && ($0.runID != scope.runID || $0.approvalID != nil)
      }
    } catch {
      return true
    }
  }
}

// MARK: - Event Routing

private extension TurnPresentationRegistry {
  func publish(_ event: TurnProgressEvent, runID: Int64) async {
    guard let entry = entries[runID] else {
      return
    }
    if case .toolState(let id, .awaitingApproval) = event {
      // Waiting is visible only after the durable suspend succeeds.
      entries[runID]?.pendingStep = id
      return
    }
    await entry.presentation.publish(event)
  }
}
