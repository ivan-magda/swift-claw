import Foundation

/// The exact concrete action an approval is bound to — the tool plus its fully-resolved target.
/// `target` is the canonical, owner-visible form of what the tool will act on (for `web_fetch`,
/// the canonical URL). Approvals match on EXACT equality of the whole action, so an approval for
/// one tool can never authorize another.
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
  case codeExec = "code_exec"
  case hostShell = "host_shell"

  /// Whether the prompt may offer to widen this approval to the rest of the turn. Exhaustive, so a
  /// new reason has to decide; the reason is the only part of the offer that survives on the
  /// durable row, which is what lets the callback path refuse a widening verdict it never offered.
  public var offersTurnScopedWindow: Bool {
    switch self {
    case .exfilTrifecta, .askTier, .codeExec:
      false
    case .hostShell:
      true
    }
  }
}

/// The tool-specific prompt inputs, produced at gate time by the tool that will act. The gate
/// records them so the durable prompt never re-derives blast radius from a stale or unparsed
/// argument form.
public struct ToolApprovalPresentation: Sendable, Equatable {
  /// e.g. "create, 1.2 KB" / "overwrite, 340 B" / "egress to <host>".
  public let blastRadius: String
  /// Tool-authored and exact-secret-redacted; write tools cap their preview, while code execution
  /// renders its complete 16 KiB-bounded script. Nil for tools with no preview.
  public let contentPreview: String?
  /// `memory_write` scan warnings; empty otherwise.
  public let warnings: [String]

  public init(blastRadius: String, contentPreview: String?, warnings: [String]) {
    self.blastRadius = blastRadius
    self.contentPreview = contentPreview
    self.warnings = warnings
  }
}

/// Everything a dangerous-tier approval binds, produced by the tool at gate time. The canonical
/// JSON REPLACES the model's raw arguments for hashing, persistence, and approved execution.
public struct PreparedToolAction: Sendable, Equatable {
  public let canonicalTarget: String
  public let canonicalArgsJSON: String
  public let presentation: ToolApprovalPresentation
  public let guardTexts: [String]
  public let canExfiltrate: Bool
  /// The prompt copy this action asks under. The acting tool names it — the gate cannot tell a
  /// disposable sandbox from the owner's own machine, and the two need different owner-facing copy.
  public let approvalReason: ApprovalReason

  public init(
    canonicalTarget: String,
    canonicalArgsJSON: String,
    presentation: ToolApprovalPresentation,
    guardTexts: [String],
    canExfiltrate: Bool,
    approvalReason: ApprovalReason
  ) {
    self.canonicalTarget = canonicalTarget
    self.canonicalArgsJSON = canonicalArgsJSON
    self.presentation = presentation
    self.guardTexts = guardTexts
    self.canExfiltrate = canExfiltrate
    self.approvalReason = approvalReason
  }
}

public enum PreparedActionResolution: Sendable, Equatable {
  case prepared(PreparedToolAction)
  case refused(reason: String)
}

/// Everything the suspend commit records and the approval binds to. The recorded canonical
/// args are what execute at resume time — never a fresh model turn.
public struct RecordedToolAction: Sendable, Equatable {
  public let tool: String
  /// Canonical (sorted-keys) JSON of the call arguments.
  public let canonicalArgsJSON: String
  /// SHA-256 hex of `canonicalArgsJSON`; the approve CAS recomputes and compares it.
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

/// The ask-tier proposal that parked a run: the `tool_call_id` its placeholder observation
/// answers, plus the recorded canonical action the approval binds to and the waiter later
/// replays. `RecordedToolAction` is Equatable, so `TurnResult.suspended` stays Equatable. Lives
/// in ClawCore so the suspend commit (`RunStore`) and its GRDB store can bind to it without a
/// dependency on ClawAgent.
public struct PendingToolAction: Sendable, Equatable {
  public let toolCallId: String
  public let recorded: RecordedToolAction

  public init(toolCallId: String, recorded: RecordedToolAction) {
    self.toolCallId = toolCallId
    self.recorded = recorded
  }
}
