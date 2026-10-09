import ClawCore
import Foundation

/// Bounded presentation values; no tool arguments, outputs, or provider replay are retained.
public struct TurnProgressState: Sendable {
  private let showsProgress: Bool
  private let secretValues: [String]

  private var phase: TurnProgressPhase
  private var providerCallID: String?
  private var answerPreview = ""

  private var explanationItemID: String?
  private var supersededExplanationItemIDs: Set<String> = []
  private var explanationRedactor: StreamingProgressText
  private var explanationText = ""

  private var steps: [TurnToolStep] = []
  private var olderSteps = TurnToolCounts(succeeded: 0, failed: 0, denied: 0, cancelled: 0)
  private var unregisteredSteps: Set<TurnToolStepID> = []
  private var coderSubmissions: Set<TurnToolStepID> = []

  public init(showsProgress: Bool, resumed: Bool, secretValues: [String]) {
    self.showsProgress = showsProgress
    self.secretValues = secretValues
    phase = resumed ? .resumed : .preparing
    explanationRedactor = StreamingProgressText(secretValues: secretValues)
  }

  public mutating func apply(_ event: TurnProgressEvent) {
    switch event {
    case .modelStarted(let callID):
      providerCallID = callID
      explanationItemID = nil
      supersededExplanationItemIDs.removeAll()
      resetExplanation()
      answerPreview = ""
      phase = .model
    case .answerPreview(let text):
      let redactedText = SecretRedactor(secretValues: secretValues).redact(text)
      answerPreview = String(
        redactedText.prefix(TelegramMessageLimits.maxRichMessageCharacters)
      )

      if !answerPreview.isEmpty {
        phase = .answer
      }
    case .explanation(let event):
      applyExplanation(event)
    case .toolStarted(let id, let tool, let preview):
      startTool(id: id, tool: tool, preview: preview)
    case .toolState(let id, let state):
      updateTool(id: id, state: state)
    case .waitingForApproval(let id):
      updateTool(id: id, state: .awaitingApproval)
    }
  }

  public func snapshot(elapsedSeconds: Int) -> TurnProgressSnapshot {
    let explanation = ProgressText.preview(
      explanationText,
      secretValues: [],
      limit: TurnProgressLimits.explanationCharacters
    )
    return TurnProgressSnapshot(
      phase: phase,
      elapsedSeconds: max(0, elapsedSeconds),
      explanation: explanation.isEmpty ? nil : explanation,
      steps: steps,
      olderSteps: olderSteps,
      answerPreview: answerPreview,
      showsProgress: showsProgress
    )
  }
}

// MARK: - Explanation Updates

private extension TurnProgressState {
  mutating func resetExplanation() {
    explanationText = ""
    explanationRedactor = StreamingProgressText(secretValues: secretValues)
  }

  mutating func applyExplanation(_ event: LLMProgressEvent) {
    guard providerCallID != nil, !supersededExplanationItemIDs.contains(event.itemID) else {
      return
    }

    if case .complete = event.text, explanationItemID != event.itemID {
      return
    }

    if explanationItemID != event.itemID {
      if let explanationItemID {
        supersededExplanationItemIDs.insert(explanationItemID)
      }
      explanationItemID = event.itemID
      resetExplanation()
    }

    let redactedText: String
    switch event.text {
    case .append(let text):
      redactedText = explanationRedactor.append(text)
    case .replace(let text):
      resetExplanation()
      redactedText = explanationRedactor.append(text)
    case .complete:
      redactedText = explanationRedactor.finish()
    }

    let combinedText = explanationText + redactedText
    explanationText = String(combinedText.prefix(TurnProgressLimits.explanationCharacters))
  }
}

// MARK: - Tool Updates

private extension TurnProgressState {
  static let unknownToolLabel = "Unknown tool"

  mutating func startTool(id: TurnToolStepID, tool: ToolDefinition?, preview: String?) {
    answerPreview = ""
    phase = .tool

    let step: TurnToolStep
    if let tool {
      step = TurnToolStep(
        id: id,
        label: toolLabel(tool.name),
        preview: allowedPreview(name: tool.name, preview: preview),
        state: .pending,
        action: TurnToolAction(registeredName: tool.name)
      )
    } else {
      step = TurnToolStep(
        id: id,
        label: Self.unknownToolLabel,
        preview: nil,
        state: .failed,
        action: .tool
      )
    }

    storeToolStep(step)
    unregisteredSteps.remove(id)
    coderSubmissions.remove(id)

    if tool == nil {
      unregisteredSteps.insert(id)
    } else if tool?.name == CoderToolNames.submit {
      coderSubmissions.insert(id)
    }
  }

  mutating func updateTool(id: TurnToolStepID, state: ToolProgressState) {
    let stepIndex = steps.firstIndex { step in
      step.id == id
    }
    guard let stepIndex, !unregisteredSteps.contains(id) else {
      return
    }

    let step = steps[stepIndex]
    let isSubmittedCodingJob = coderSubmissions.contains(id) && state == .succeeded
    let label = isSubmittedCodingJob ? "Coding job submitted" : step.label
    steps[stepIndex] = TurnToolStep(
      id: id,
      label: label,
      preview: step.preview,
      state: state,
      action: step.action
    )

    answerPreview = ""
    let hasPendingApproval = steps.contains { step in
      step.state == .awaitingApproval
    }
    phase = hasPendingApproval ? .approval : .tool
  }
}

// MARK: - Tool Labels and Previews

private extension TurnProgressState {
  func toolLabel(_ name: String) -> String {
    let label: String
    switch name {
    case BuiltinToolNames.webSearch:
      label = "Search the web"
    case BuiltinToolNames.webFetch:
      label = "Read a page"
    case BuiltinToolNames.skillLoad:
      label = "Load a skill"
    case BuiltinToolNames.fileRead:
      label = "Read a file"
    case BuiltinToolNames.fileWrite:
      label = "Write a file"
    case BuiltinToolNames.memoryWrite:
      label = "Write memory"
    case BuiltinToolNames.executeCode:
      label = "Run code in sandbox"
    case CoderToolNames.submit:
      label = "Submit coding job"
    case CoderToolNames.status:
      label = "Check coding job status"
    case CoderToolNames.cancel:
      label = "Cancel coding job"
    default:
      // Registered MCP names include both server and tool; policy identity may contain secrets.
      label = name
    }

    return ProgressText.preview(
      label,
      secretValues: secretValues,
      limit: TurnProgressLimits.previewCharacters
    )
  }

  func allowedPreview(name: String, preview: String?) -> String? {
    guard let preview else {
      return nil
    }

    let selectedPreview: String
    switch name {
    case BuiltinToolNames.webSearch, BuiltinToolNames.skillLoad:
      selectedPreview = preview
    case BuiltinToolNames.webFetch:
      guard let page = pagePreview(preview) else {
        return nil
      }

      selectedPreview = page
    case BuiltinToolNames.fileRead, BuiltinToolNames.fileWrite:
      guard ProgressText.isWorkspaceRelativePath(preview) else {
        return nil
      }

      selectedPreview = preview
    default:
      return nil
    }

    let redactedPreview = ProgressText.preview(
      selectedPreview,
      secretValues: secretValues,
      limit: TurnProgressLimits.previewCharacters
    )

    return redactedPreview.isEmpty ? nil : redactedPreview
  }

  func pagePreview(_ preview: String) -> String? {
    let hasExplicitScheme = preview.contains("://")
    let urlText = hasExplicitScheme ? preview : "https://" + preview

    guard let url = URLComponents(string: urlText) else {
      return nil
    }

    let hasCredentials = url.user != nil || url.password != nil
    let hasQueryOrFragment = url.query != nil || url.fragment != nil
    if !hasExplicitScheme && (hasCredentials || hasQueryOrFragment) {
      return nil
    }

    return ProgressText.webPagePreview(url, secretValues: secretValues)
  }
}

// MARK: - Tool Step Retention

private extension TurnProgressState {
  mutating func storeToolStep(_ step: TurnToolStep) {
    let existingIndex = steps.firstIndex { existingStep in
      existingStep.id == step.id
    }

    if let existingIndex {
      steps[existingIndex] = step
    } else {
      makeRoomForToolStep()
      steps.append(step)
    }
  }

  mutating func makeRoomForToolStep() {
    guard steps.count == TurnProgressLimits.retainedToolSteps else {
      return
    }

    let oldestCompletedIndex = steps.firstIndex { step in
      isCompleted(step.state)
    }
    let evictionIndex = oldestCompletedIndex ?? 0
    let evictedStep = steps.remove(at: evictionIndex)
    countOlder(evictedStep.state)
    unregisteredSteps.remove(evictedStep.id)
    coderSubmissions.remove(evictedStep.id)
  }

  func isCompleted(_ state: ToolProgressState) -> Bool {
    switch state {
    case .succeeded, .failed, .denied, .cancelled:
      return true
    case .pending, .awaitingApproval, .executing:
      return false
    }
  }

  mutating func countOlder(_ state: ToolProgressState) {
    olderSteps = TurnToolCounts(
      succeeded: olderSteps.succeeded + (state == .succeeded ? 1 : 0),
      failed: olderSteps.failed + (state == .failed ? 1 : 0),
      denied: olderSteps.denied + (state == .denied ? 1 : 0),
      cancelled: olderSteps.cancelled + (state == .cancelled ? 1 : 0)
    )
  }
}
