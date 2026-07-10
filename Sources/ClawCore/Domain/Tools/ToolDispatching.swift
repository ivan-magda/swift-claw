import Foundation

/// The per-call policy inputs the gate reads. Taint and private-data are each the OR of the
/// persisted/assembly flag and the run-local flag (§9.1: `(session ∪ run)` / `(assembly ∪ run)`).
public struct ToolDispatchContext: Sendable, Equatable {
  public let sessionTainted: Bool
  public let runIngestedUntrusted: Bool
  public let assemblyPrivateData: Bool
  public let runPrivateData: Bool
  /// §4.5: the persisted `sessions.has_private_data` flag. The trifecta private-data leg is
  /// `assemblyPrivateData ∪ runPrivateData ∪ sessionHasPrivateData`, so the gate stays armed after
  /// the context window rolls past the private read that first set it (closes the §12 over-cap gap).
  public let sessionHasPrivateData: Bool
  public let approvalAlreadyPending: Bool

  public init(
    sessionTainted: Bool,
    runIngestedUntrusted: Bool,
    assemblyPrivateData: Bool,
    runPrivateData: Bool,
    sessionHasPrivateData: Bool,
    approvalAlreadyPending: Bool
  ) {
    self.sessionTainted = sessionTainted
    self.runIngestedUntrusted = runIngestedUntrusted
    self.assemblyPrivateData = assemblyPrivateData
    self.runPrivateData = runPrivateData
    self.sessionHasPrivateData = sessionHasPrivateData
    self.approvalAlreadyPending = approvalAlreadyPending
  }
}

/// One dispatched call's full result: the observation, the audit-safe args rendering (§9.1 —
/// matched spans replaced, never the secret), and the recorded action when the gate parked the
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
