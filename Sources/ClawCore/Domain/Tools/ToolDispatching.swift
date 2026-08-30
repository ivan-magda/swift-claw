import Foundation

/// The per-call policy inputs the gate reads. Taint and private-data are each the OR of the
/// persisted/assembly flag and the run-local flag (`(session ∪ run)` / `(assembly ∪ run)`).
public struct ToolDispatchContext: Sendable, Equatable {
  public let sessionTainted: Bool
  public let runIngestedUntrusted: Bool
  public let assemblyPrivateData: Bool
  public let runPrivateData: Bool
  /// The persisted `sessions.has_private_data` flag. The trifecta private-data leg is
  /// `assemblyPrivateData ∪ runPrivateData ∪ sessionHasPrivateData`, so the gate stays armed after
  /// the context window rolls past the private read that first set it.
  public let sessionHasPrivateData: Bool
  public let approvalAlreadyPending: Bool
  /// How the conversation is served. A group topic has no approval keyboard and no single owner
  /// to press it, so the gate resolves consent itself instead of parking a prompt nobody owns.
  public let mode: ChatMode

  public init(
    sessionTainted: Bool,
    runIngestedUntrusted: Bool,
    assemblyPrivateData: Bool,
    runPrivateData: Bool,
    sessionHasPrivateData: Bool,
    approvalAlreadyPending: Bool,
    mode: ChatMode = .direct
  ) {
    self.sessionTainted = sessionTainted
    self.runIngestedUntrusted = runIngestedUntrusted
    self.assemblyPrivateData = assemblyPrivateData
    self.runPrivateData = runPrivateData
    self.sessionHasPrivateData = sessionHasPrivateData
    self.approvalAlreadyPending = approvalAlreadyPending
    self.mode = mode
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
