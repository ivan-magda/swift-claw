import ClawAgent
import ClawCore
import Foundation

/// Presentation admission and delivery exclusion; session lanes still own execution order.
public actor TurnPresentationRegistry {
  struct Entry {
    let scope: TurnScope
    let presentation: TurnPresentation
    let reporter: TurnProgressReporter
    var pendingApprovalStepID: TurnToolStepID?
  }

  private let streamingEnabled: Bool
  private let progressEnabled: Bool
  private let renderer: any TurnProgressRendering
  private let drafts: any RichDraftStreaming
  private let typing: any TypingIndicator
  private let outbox: any OutboxStore
  private let secretValues: [String]
  private let clock: any Clock<Duration>
  private var entriesByRunID: [Int64: Entry] = [:]
  private var deliveryLeases: [UUID: Int64] = [:]
  private var pauseRevision = 0
  private var isShutDown = false

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

  // MARK: - Presentation Admission

  public func begin(scope: TurnScope, resumed: Bool = false) async -> TurnProgressReporter? {
    guard !Task.isCancelled, !isShutDown, scope.origin == .interactive else {
      return nil
    }

    if let entry = entriesByRunID[scope.runID] {
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
    let reporter = TurnProgressReporter(
      explanationsEnabled: progressEnabled
    ) { [weak self] event in
      await self?.publish(event, runID: scope.runID)
    }
    let entry = Entry(
      scope: scope,
      presentation: presentation,
      reporter: reporter
    )
    // No suspension between cancellation/shutdown admission and registration.
    entriesByRunID[scope.runID] = entry
    await presentation.start()
    await updateDraftPause(for: entry)

    return reporter
  }

  // MARK: - Approval Progress

  public func waitingForApproval(runID: Int64) async {
    guard let entry = entriesByRunID[runID],
          let stepID = entry.pendingApprovalStepID
    else {
      return
    }

    await entry.presentation.publish(.waitingForApproval(id: stepID))
  }

  public func approvalProgress(runID: Int64, toolCallID: String) -> ToolProgressReporter? {
    guard let entry = entriesByRunID[runID] else {
      return nil
    }

    let stepID =
      entry.pendingApprovalStepID
      ?? TurnToolStepID(
        providerCallID: UUID().uuidString,
        toolCallID: toolCallID
      )
    entriesByRunID[runID]?.pendingApprovalStepID = stepID

    return ToolProgressReporter(
      identify: { tool, preview in
        await entry.reporter.publish(.toolStarted(id: stepID, tool: tool, preview: preview))
      },
      publish: { state in
        await entry.reporter.publish(.toolState(id: stepID, state: state))
      }
    )
  }

  // MARK: - Presentation Lifecycle

  public func close(runID: Int64) async {
    guard let entry = entriesByRunID[runID] else {
      return
    }

    await entry.presentation.closeAndAwait()

    if entriesByRunID[runID]?.presentation === entry.presentation {
      entriesByRunID.removeValue(forKey: runID)
    }
  }

  public func close(sessionID: Int64) async {
    let sessionEntries = entriesByRunID.values.filter { entry in
      entry.scope.sessionID == sessionID
    }

    for entry in sessionEntries {
      await close(runID: entry.scope.runID)
    }
  }

  public func shutdown() async {
    isShutDown = true
    let runIDs = Array(entriesByRunID.keys)
    for runID in runIDs {
      await close(runID: runID)
    }
  }

  // MARK: - Delivery Leases

  public func beginDelivery(to target: DeliveryTarget) async -> UUID {
    let leaseID = UUID()
    deliveryLeases[leaseID] = target.chatID

    await updateDraftPauses(inChat: target.chatID)

    return leaseID
  }

  public func endDelivery(_ leaseID: UUID) async {
    guard let chatID = deliveryLeases.removeValue(forKey: leaseID) else {
      return
    }

    await updateDraftPauses(inChat: chatID)
  }
}

// MARK: - Delivery Holds

private extension TurnPresentationRegistry {
  func updateDraftPauses(inChat chatID: Int64) async {
    let chatEntries = entriesByRunID.values.filter { entry in
      entry.scope.chatID == chatID
    }

    for entry in chatEntries {
      await updateDraftPause(for: entry)
    }
  }

  func updateDraftPause(for entry: Entry) async {
    pauseRevision += 1
    let shouldPauseDrafts = holdsDrafts(for: entry.scope)
    await entry.presentation.setDraftsPaused(shouldPauseDrafts, revision: pauseRevision)
  }

  func holdsDrafts(for scope: TurnScope) -> Bool {
    if deliveryLeases.values.contains(scope.chatID) {
      return true
    }

    do {
      let pendingMessages = try outbox.pendingOutbound()
      return pendingMessages.contains { message in
        let isSameChat = message.chatID == scope.chatID
        let isOtherRun = message.runID != scope.runID
        let isApprovalCard = message.approvalID != nil
        return isSameChat && (isOtherRun || isApprovalCard)
      }
    } catch {
      // Keep drafts paused when pending permanent deliveries cannot be checked.
      return true
    }
  }
}

// MARK: - Event Routing

private extension TurnPresentationRegistry {
  func publish(_ event: TurnProgressEvent, runID: Int64) async {
    guard let entry = entriesByRunID[runID] else {
      return
    }

    if case .toolState(let stepID, .awaitingApproval) = event {
      // Waiting is visible only after the durable suspend succeeds.
      entriesByRunID[runID]?.pendingApprovalStepID = stepID
      return
    }

    await entry.presentation.publish(event)
  }
}
