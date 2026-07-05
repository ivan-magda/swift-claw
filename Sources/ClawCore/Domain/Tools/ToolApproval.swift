import Foundation

/// The exact concrete action an approval and its grant are bound to — FR-T5's "tool +
/// fully-resolved target". `target` is the canonical, owner-visible form of what the tool will
/// act on (for `web_fetch`, the canonical URL). Grants match on EXACT equality of the whole
/// action, so an approval for one tool can never authorize another.
public struct ToolAction: Sendable, Equatable {
  public let tool: String
  public let target: String

  public init(tool: String, target: String) {
    self.tool = tool
    self.target = target
  }
}

/// Why the gate parked an approval. The rawValue is the stable vocabulary; every case must
/// render in `ToolApprovalPrompt`, so adding an approval-needing tool cannot compile without
/// its owner-facing copy. A reason names ONE tool operation — a new tool adds its own case,
/// never reuses one, because the prompt copy is keyed on the reason alone.
public enum ApprovalReason: String, Sendable, Equatable {
  case exfilTrifecta = "exfil_trifecta"
}

/// A gate trip awaiting the owner's ephemeral text approval (§9.2). Carries the action identity
/// and reason only; the deterministic prompt text is authored in ClawGateway at the delivery
/// seam (D7).
public struct ToolApprovalRequest: Sendable, Equatable {
  public let action: ToolAction
  public let reason: ApprovalReason

  public init(action: ToolAction, reason: ApprovalReason) {
    self.action = action
    self.reason = reason
  }
}

/// The single-use, one-turn grant a `yes` arms: it authorizes exactly one future call whose
/// action equals the approved one (grant semantics, not recorded-args replay).
public struct OneTurnGrant: Sendable, Equatable {
  public let action: ToolAction

  public init(action: ToolAction) {
    self.action = action
  }
}
