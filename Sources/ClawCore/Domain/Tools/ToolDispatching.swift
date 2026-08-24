import Foundation

/// The per-call policy inputs the gate reads, plus the identity of the run that made the call.
/// Taint and private-data are each the OR of the persisted/assembly flag and the run-local flag
/// (`(session ∪ run)` / `(assembly ∪ run)`).
public struct ToolDispatchContext: Sendable, Equatable {
  /// The run the call belongs to, and the chat that reads its delivery sequence. Not policy: this
  /// is what a pre-execution announcement (`ToolInvocationEchoing`) is addressed to, and the
  /// dispatcher is the only place that knows a call will execute before it does.
  public let runId: Int64
  public let chatId: Int64
  public let sessionTainted: Bool
  public let runIngestedUntrusted: Bool
  public let assemblyPrivateData: Bool
  public let runPrivateData: Bool
  /// The persisted `sessions.has_private_data` flag. The trifecta private-data leg is
  /// `assemblyPrivateData ∪ runPrivateData ∪ sessionHasPrivateData`, so the gate stays armed after
  /// the context window rolls past the private read that first set it.
  public let sessionHasPrivateData: Bool
  public let approvalAlreadyPending: Bool
  /// Which pathway created the run, so the gate can refuse a tool that needs the owner present
  /// (`ToolDefinition.requiresInteractiveRun`) instead of parking an approval nobody will answer.
  public let runOrigin: RunOrigin
  /// Whether the run carries an open turn-scoped auto-approve window. The owner opened it on one
  /// approval prompt, so only an action whose `ApprovalReason.offersTurnScopedWindow` is true may
  /// ride it, and only after the same argument scans a parked call takes.
  public let autoApproveWindowOpen: Bool

  public init(
    runId: Int64,
    chatId: Int64,
    sessionTainted: Bool,
    runIngestedUntrusted: Bool,
    assemblyPrivateData: Bool,
    runPrivateData: Bool,
    sessionHasPrivateData: Bool,
    approvalAlreadyPending: Bool,
    runOrigin: RunOrigin,
    autoApproveWindowOpen: Bool
  ) {
    self.runId = runId
    self.chatId = chatId
    self.sessionTainted = sessionTainted
    self.runIngestedUntrusted = runIngestedUntrusted
    self.assemblyPrivateData = assemblyPrivateData
    self.runPrivateData = runPrivateData
    self.sessionHasPrivateData = sessionHasPrivateData
    self.approvalAlreadyPending = approvalAlreadyPending
    self.runOrigin = runOrigin
    self.autoApproveWindowOpen = autoApproveWindowOpen
  }
}

/// One dispatched call's full result: the observation, the audit-safe args rendering (matched
/// spans replaced, never the secret), and the recorded action when the gate parked the
/// call for the owner's durable approval.
public struct ToolDispatchOutcome: Sendable, Equatable {
  public let observation: ToolObservation
  public let argsRedacted: String
  public let requiresApproval: RecordedToolAction?

  public init(
    observation: ToolObservation,
    argsRedacted: String,
    requiresApproval: RecordedToolAction? = nil
  ) {
    self.observation = observation
    self.argsRedacted = argsRedacted
    self.requiresApproval = requiresApproval
  }
}

/// The loop's one seam onto tools: registry lookup, arg parse, policy gate, timeout, and
/// execution all live behind it (`ClawTools.GatedToolDispatcher` in production; a scripted fake
/// in loop tests). Keeps the module DAG intact — ClawAgent never imports ClawTools.
public protocol ToolDispatching: Sendable {
  var definitions: [ToolDefinition] { get }

  func dispatch(call: ToolCall, context: ToolDispatchContext) async -> ToolDispatchOutcome
}
