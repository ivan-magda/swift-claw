public enum TurnProgressPhase: Sendable, Equatable {
  case preparing
  case model
  case tool
  case approval
  case answer
  case resumed
}

public struct TurnToolStep: Sendable, Equatable {
  public let id: TurnToolStepID
  public let label: String
  public let preview: String?
  public let state: ToolProgressState
  public let action: TurnToolAction

  public init(
    id: TurnToolStepID,
    label: String,
    preview: String?,
    state: ToolProgressState,
    action: TurnToolAction
  ) {
    self.id = id
    self.label = label
    self.preview = preview
    self.state = state
    self.action = action
  }
}

public struct TurnToolCounts: Sendable, Equatable {
  public let succeeded: Int
  public let failed: Int
  public let denied: Int
  public let cancelled: Int

  public init(succeeded: Int, failed: Int, denied: Int, cancelled: Int) {
    self.succeeded = succeeded
    self.failed = failed
    self.denied = denied
    self.cancelled = cancelled
  }
}

public struct TurnProgressSnapshot: Sendable, Equatable {
  public let phase: TurnProgressPhase
  public let elapsedSeconds: Int
  public let explanation: String?
  public let steps: [TurnToolStep]
  public let olderSteps: TurnToolCounts
  public let answerPreview: String
  public let showsProgress: Bool

  public init(
    phase: TurnProgressPhase,
    elapsedSeconds: Int,
    explanation: String?,
    steps: [TurnToolStep],
    olderSteps: TurnToolCounts,
    answerPreview: String,
    showsProgress: Bool
  ) {
    self.phase = phase
    self.elapsedSeconds = elapsedSeconds
    self.explanation = explanation
    self.steps = steps
    self.olderSteps = olderSteps
    self.answerPreview = answerPreview
    self.showsProgress = showsProgress
  }
}

public protocol TurnProgressRendering: Sendable {
  func render(_ snapshot: TurnProgressSnapshot) -> String?

  func renderDraft(_ snapshot: TurnProgressSnapshot) -> RichDraft?
}

extension TurnProgressRendering {
  public func renderDraft(_ snapshot: TurnProgressSnapshot) -> RichDraft? {
    render(snapshot).map(RichDraft.init(markdown:))
  }
}

public enum TurnProgressLimits {
  public static let explanationCharacters = 160
  public static let previewCharacters = 120
  public static let retainedToolSteps = 32
  public static let visibleToolSteps = 6
  public static let markupCharacters = 2_048
}
