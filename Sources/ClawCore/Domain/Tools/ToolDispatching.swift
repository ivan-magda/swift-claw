import Foundation

/// The per-call policy inputs the gate reads. Taint and private-data are each the OR of the
/// persisted/assembly flag and the run-local flag (§9.1: `(session ∪ run)` / `(assembly ∪ run)`).
public struct ToolDispatchContext: Sendable, Equatable {
  public let sessionTainted: Bool
  public let runIngestedUntrusted: Bool
  public let assemblyPrivateData: Bool
  public let runPrivateData: Bool
  public let grant: OneTurnGrant?
  public let approvalAlreadyPending: Bool
  /// True for scheduled/heartbeat runs (§10): the gate converts every would-park approval
  /// outcome into an immediate audited DENY. No default — every construction site decides
  /// explicitly (secure-by-default; a forgotten site is a compile error, not a privilege grant).
  public let nonInteractive: Bool

  public init(
    sessionTainted: Bool,
    runIngestedUntrusted: Bool,
    assemblyPrivateData: Bool,
    runPrivateData: Bool,
    grant: OneTurnGrant?,
    approvalAlreadyPending: Bool,
    nonInteractive: Bool
  ) {
    self.sessionTainted = sessionTainted
    self.runIngestedUntrusted = runIngestedUntrusted
    self.assemblyPrivateData = assemblyPrivateData
    self.runPrivateData = runPrivateData
    self.grant = grant
    self.approvalAlreadyPending = approvalAlreadyPending
    self.nonInteractive = nonInteractive
  }
}

/// One dispatched call's full result: the observation, the audit-safe args rendering (§9.1 —
/// matched spans replaced, never the secret), the first-trip approval request, and whether the
/// grant was consumed.
public struct ToolDispatchOutcome: Sendable, Equatable {
  public let observation: ToolObservation
  public let argsRedacted: String
  public let pendingApproval: ToolApprovalRequest?
  public let consumedGrant: Bool

  public init(
    observation: ToolObservation,
    argsRedacted: String,
    pendingApproval: ToolApprovalRequest? = nil,
    consumedGrant: Bool = false
  ) {
    self.observation = observation
    self.argsRedacted = argsRedacted
    self.pendingApproval = pendingApproval
    self.consumedGrant = consumedGrant
  }
}

/// The loop's one seam onto tools: registry lookup, arg parse, policy gate, timeout, and
/// execution all live behind it (`ClawTools.GatedToolDispatcher` in production; a scripted fake
/// in loop tests). Keeps the module DAG intact — ClawAgent never imports ClawTools.
public protocol ToolDispatching: Sendable {
  var definitions: [ToolDefinition] { get }

  func dispatch(call: ToolCall, context: ToolDispatchContext) async -> ToolDispatchOutcome
}
