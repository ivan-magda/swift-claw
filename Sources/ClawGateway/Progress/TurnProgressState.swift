import ClawCore
import Foundation

/// Bounded presentation values; no tool arguments, outputs, or provider replay are retained.
public struct TurnProgressState: Sendable {
  private let showsProgress: Bool
  private let secretValues: [String]
  private var phase: TurnProgressPhase
  private var providerCallID: String?
  private var explanationItemID: String?
  private var explanationRedactor: StreamingProgressText
  private var explanationText = ""
  private var answerPreview = ""
  private var steps: [TurnToolStep] = []
  private var unregisteredSteps: Set<TurnToolStepID> = []
  private var coderSubmissions: Set<TurnToolStepID> = []
  private var olderSteps = TurnToolCounts(succeeded: 0, failed: 0, denied: 0, cancelled: 0)

  public init(showsProgress: Bool, resumed: Bool, secretValues: [String]) {
    self.showsProgress = showsProgress
    self.secretValues = secretValues
    phase = resumed ? .resumed : .preparing
    explanationRedactor = StreamingProgressText(secretValues: secretValues)
  }

  public mutating func apply(_ event: TurnProgressEvent) {
    switch event {
    case .modelStarted(let id):
      providerCallID = id
      explanationItemID = nil
      resetExplanation()
      answerPreview = ""
      phase = .model
    case .answerPreview(let text):
      answerPreview = String(
        SecretRedactor(secretValues: secretValues).redact(text)
          .prefix(TelegramMessageLimits.maxRichMessageCharacters)
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
    guard providerCallID != nil else {
      return
    }

    if case .complete = event.text, explanationItemID != event.itemID {
      return
    }

    if explanationItemID != event.itemID {
      explanationItemID = event.itemID
      resetExplanation()
    }

    let safe: String
    switch event.text {
    case .append(let text):
      safe = explanationRedactor.append(text)
    case .replace(let text):
      resetExplanation()
      safe = explanationRedactor.append(text)
    case .complete:
      safe = explanationRedactor.finish()
    }

    explanationText = String(
      (explanationText + safe).prefix(TurnProgressLimits.explanationCharacters)
    )
  }
}

// MARK: - Tool Updates

private extension TurnProgressState {
  static let unknownToolLabel = "Unknown tool"

  mutating func startTool(id: TurnToolStepID, tool: ToolDefinition?, preview: String?) {
    answerPreview = ""
    phase = .tool
    let step = TurnToolStep(
      id: id,
      label: tool.map {
        toolLabel($0.name)
      } ?? Self.unknownToolLabel,
      preview: tool.flatMap {
        allowedPreview(name: $0.name, preview: preview)
      },
      state: tool == nil ? .failed : .pending
    )

    if let index = steps.firstIndex(where: {
      $0.id == id
    }) {
      steps[index] = step
    } else {
      if steps.count == TurnProgressLimits.retainedToolSteps {
        let index =
          steps.firstIndex {
            isCompleted($0.state)
          } ?? 0
        let removed = steps.remove(at: index)
        countOlder(removed.state)
        unregisteredSteps.remove(removed.id)
        coderSubmissions.remove(removed.id)
      }
      steps.append(step)
    }
    unregisteredSteps.remove(id)
    coderSubmissions.remove(id)
    if tool == nil {
      unregisteredSteps.insert(id)
    } else if tool?.name == CoderToolNames.submit {
      coderSubmissions.insert(id)
    }
  }

  mutating func updateTool(id: TurnToolStepID, state: ToolProgressState) {
    guard let index = steps.firstIndex(where: {
        $0.id == id
      }),
          !unregisteredSteps.contains(id)
    else {
      return
    }

    let step = steps[index]
    let label =
      coderSubmissions.contains(id) && state == .succeeded
      ? "Coding job submitted" : step.label
    steps[index] = TurnToolStep(id: id, label: label, preview: step.preview, state: state)

    answerPreview = ""
    phase =
      steps.contains {
        $0.state == .awaitingApproval
      } ? .approval : .tool
  }

  func toolLabel(_ name: String) -> String {
    let label: String
    switch name {
    case "web_search":
      label = "Search the web"
    case "web_fetch":
      label = "Read a page"
    case "skill_load":
      label = "Load a skill"
    case "file_read":
      label = "Read a file"
    case "file_write":
      label = "Write a file"
    case "memory_write":
      label = "Write memory"
    case "execute_code":
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

    let selected: String
    switch name {
    case "web_search", "skill_load":
      selected = preview
    case "web_fetch":
      guard let page = pagePreview(preview) else {
        return nil
      }
      selected = page
    case "file_read", "file_write":
      guard isWorkspaceRelativePath(preview) else {
        return nil
      }
      selected = preview
    default:
      return nil
    }

    let safe = ProgressText.preview(
      selected,
      secretValues: secretValues,
      limit: TurnProgressLimits.previewCharacters
    )

    return safe.isEmpty ? nil : safe
  }

  func pagePreview(_ preview: String) -> String? {
    let isURL = preview.contains("://")
    let raw = isURL ? preview : "https://" + preview

    guard let url = URLComponents(string: raw) else {
      return nil
    }

    if !isURL
       && (url.user != nil || url.password != nil || url.query != nil || url.fragment != nil)
    {
      return nil
    }

    return ProgressText.webPagePreview(url, secretValues: secretValues)
  }

  func isWorkspaceRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
          !path.contains("\\"), !path.contains(":"),
          !path.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else {
      return false
    }

    let parts = path.split(separator: "/", omittingEmptySubsequences: false)

    return parts.allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
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
