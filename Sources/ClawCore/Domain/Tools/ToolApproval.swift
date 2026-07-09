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
  case askTier = "ask_tier"
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

/// The §5.4 tool-specific prompt inputs, produced at gate time by the tool that will act. The gate
/// records them so the durable prompt (Task 13) never re-derives blast radius from a stale or
/// unparsed argument form.
public struct ToolApprovalPresentation: Sendable, Equatable {
  /// e.g. "create, 1.2 KB" / "overwrite, 340 B" / "egress to <host>".
  public let blastRadius: String
  /// Size-capped, secret-redacted; nil for non-write tools.
  public let contentPreview: String?
  /// `memory_write` scan warnings; empty otherwise.
  public let warnings: [String]

  public init(blastRadius: String, contentPreview: String?, warnings: [String]) {
    self.blastRadius = blastRadius
    self.contentPreview = contentPreview
    self.warnings = warnings
  }
}

/// Everything the §5.3 suspend commit records and the approval binds to. The recorded canonical
/// args are what execute at resume time (§6.3) — never a fresh model turn.
public struct RecordedToolAction: Sendable, Equatable {
  public let tool: String
  /// Canonical (sorted-keys) JSON of the call arguments.
  public let canonicalArgsJSON: String
  /// SHA-256 hex of `canonicalArgsJSON`; the approve CAS recomputes and compares it (§6.2 step 5).
  public let argsHash: String
  public let canonicalTarget: String
  public let reason: ApprovalReason
  public let presentation: ToolApprovalPresentation

  public init(
    tool: String,
    canonicalArgsJSON: String,
    argsHash: String,
    canonicalTarget: String,
    reason: ApprovalReason,
    presentation: ToolApprovalPresentation
  ) {
    self.tool = tool
    self.canonicalArgsJSON = canonicalArgsJSON
    self.argsHash = argsHash
    self.canonicalTarget = canonicalTarget
    self.reason = reason
    self.presentation = presentation
  }
}

/// The ask-tier proposal that parked a run (§5.2): the `tool_call_id` its placeholder observation
/// answers, plus the recorded canonical action the approval binds to and the waiter later replays
/// (§6.3). `RecordedToolAction` is Equatable, so `TurnResult.suspended` stays Equatable. Lives in
/// ClawCore so the §5.3 suspend commit (`RunStore`) and its GRDB store can bind to it without a
/// dependency on ClawAgent.
public struct PendingToolAction: Sendable, Equatable {
  public let toolCallId: String
  public let recorded: RecordedToolAction

  public init(toolCallId: String, recorded: RecordedToolAction) {
    self.toolCallId = toolCallId
    self.recorded = recorded
  }
}
