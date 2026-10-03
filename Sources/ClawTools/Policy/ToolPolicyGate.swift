import ClawCore
import Foundation

/// The single policy gate for safe, ask-tier, and dangerous tools. Safe egress retains the
/// unconditional/trifecta tiers; ask-tier actions resolve owner consent; dangerous actions may
/// park only after the tool prepares, scans, and binds the exact recorded action.
public struct ToolPolicyGate: Sendable {
  public enum Verdict: Sendable, Equatable {
    /// `action` is the gate-resolved canonical action for `.arbitraryDestination` tools — the
    /// dispatcher hands its target into `execute` so the tool acts on exactly the form the gate
    /// authorized; `nil` for the other classes. An ask-tier tool allowed without an approval
    /// carries its resolved target here too, because its `execute` requires one.
    ///
    /// `preparedArgsJSON` is the dangerous tier's prepared canonical arguments, present only when
    /// the gate allowed a dangerous action outright. `execute` decodes that recorded shape, not
    /// the model's raw arguments, so the dispatcher must hand it over verbatim.
    case allow(argsRedacted: String, action: ToolAction?, preparedArgsJSON: String? = nil)
    case block(payload: ToolPayload, argsRedacted: String)
    /// An ask-tier action parked for the owner's durable approval. Carries the recorded
    /// canonical args the suspend commit persists and the resume replays.
    case requireApproval(recorded: RecordedToolAction)
  }

  private let argGuard: ExfilArgGuard
  private let privateFileLoader: @Sendable () -> [String]
  private let enabledDangerousTools: Set<String>

  public init(
    argGuard: ExfilArgGuard,
    privateFileLoader: @escaping @Sendable () -> [String],
    enabledDangerousTools: Set<String>
  ) {
    self.argGuard = argGuard
    self.privateFileLoader = privateFileLoader
    self.enabledDangerousTools = enabledDangerousTools
  }

  public func evaluate(
    call: ToolCall,
    tool: any Tool,
    context: ToolDispatchContext
  ) async -> Verdict {
    if let refusal = requesterAdmissionRefusal(call: call, tool: tool, context: context) {
      return refusal
    }
    // Total over RiskLevel. Ask-tier resolves before the egress fast-path so a `.none`-egress
    // ask tool (file_write) still parks; dangerous consumes only a tool-prepared action; safe
    // egress falls through to the unconditional/trifecta tiers below.
    switch tool.definition.riskLevel {
    case .ask:
      return evaluateAskTier(call: call, tool: tool, context: context)
    case .dangerous:
      return await evaluateDangerousTier(call: call, tool: tool, context: context)
    case .safe:
      break
    }

    // .none-egress fast path — a safe non-egress read (file_read): audit-render only.
    guard tool.definition.egressClass != .none else {
      return .allow(
        argsRedacted: argGuard.renderRedacted(argsJSON: call.argumentsJSON),
        action: nil
      )
    }

    let argsRedacted: String
    switch scanArguments(call: call, context: context) {
    case .blocked(let verdict):
      return verdict
    case .cleared(let redacted, let trifectaHeld):
      // A group topic has nobody to hold the approval, so a held trifecta allows: the
      // unconditional and conditional argument scans above already ran and still block.
      guard trifectaHeld, context.mode == .direct else {
        return resolveAndAllow(call: call, tool: tool, argsRedacted: redacted)
      }
      argsRedacted = redacted
    }

    // Trifecta arm — DURABLE: a would-park action suspends onto the approval fabric. Non-interactive
    // runs take the SAME park (→ EXPIRED → DENY), never an immediate gate DENY.
    let action: ToolAction?
    switch resolveAction(call: call, tool: tool) {
    case .action(let resolved):
      action = resolved
    case .blocked(let payload):
      return .block(payload: payload, argsRedacted: argsRedacted)
    }
    guard let action else {
      return .allow(argsRedacted: argsRedacted, action: nil)
    }

    guard context.approvalAlreadyPending == false else {
      // One pending approval per run — a further gated call observes the block, never a
      // second suspend.
      return pendingApprovalBlock(argsRedacted: argsRedacted)
    }

    let recorded = recordedAction(
      call: call,
      tool: tool,
      target: action.target,
      reason: .exfilTrifecta
    )
    return .requireApproval(recorded: recorded)
  }

  /// The audit rendering, exposed so the dispatcher's pre-gate error paths (unknown tool,
  /// malformed args) can redact their args too — the `argsRedacted` seam field must never carry a
  /// raw secret, whatever the outcome.
  public func renderRedacted(argsJSON: String) -> String {
    argGuard.renderRedacted(argsJSON: argsJSON)
  }

  private enum ActionResolution {
    case action(ToolAction?)
    case blocked(ToolPayload)
  }

  /// Resolves the canonical action for `.arbitraryDestination` tools (`.action(nil)` for the
  /// classes with no destination). A declared arbitrary-destination tool that resolves nothing
  /// is a contract violation and fails CLOSED — never a silent walk past the approval tier.
  private func resolveAction(call: ToolCall, tool: any Tool) -> ActionResolution {
    guard tool.definition.egressClass == .arbitraryDestination else {
      return .action(nil)
    }

    guard let arguments = JSONValue.parse(call.argumentsJSON) else {
      return .blocked(
        ToolPayload(
          content: "Malformed arguments for \(call.name).",
          status: .error,
          ingestedUntrusted: false
        )
      )
    }

    switch tool.canonicalTarget(arguments: arguments) {
    case .resolved(let target):
      return .action(ToolAction(tool: call.name, target: target))
    case .refused(let reason):
      return .blocked(ToolPayload(content: reason, status: .error, ingestedUntrusted: false))
    case nil:
      return .blocked(
        ToolPayload(
          content: "\(call.name) is declared arbitrary-destination but resolved no target.",
          status: .error,
          ingestedUntrusted: false
        )
      )
    }
  }

  private func blockedArgs(rule: String, argsRedacted: String) -> Verdict {
    .block(
      payload: ToolPayload(
        // Names the rule CLASS, never the matched text
        content: "Blocked: the arguments matched the \(rule) rule and were not sent anywhere.",
        status: .blockedArgs,
        ingestedUntrusted: false
      ),
      argsRedacted: argsRedacted
    )
  }
}

// MARK: - Requester Admission

private extension ToolPolicyGate {
  func requesterAdmissionRefusal(
    call: ToolCall,
    tool: any Tool,
    context: ToolDispatchContext
  ) -> Verdict? {
    guard tool.definition.requiresInteractiveRequester else {
      return nil
    }
    guard let execution = context.executionContext,
          context.mode == execution.mode,
          execution.origin == .interactive,
          let requester = execution.requesterUserID,
          requester > 0,
          execution.mode == .group || requester == execution.chatID
    else {
      return dangerousBlock(
        reason: "\(call.name) requires an interactive message with a known requester.",
        call: call
      )
    }
    return nil
  }
}

// MARK: - Argument Scanning

private extension ToolPolicyGate {
  enum ArgumentScan {
    case blocked(Verdict)
    /// `trifectaHeld` decides whether the caller parks an approval or allows outright; the ask tier
    /// parks regardless and ignores it.
    case cleared(argsRedacted: String, trifectaHeld: Bool)
  }

  /// Runs the egress-carrying argument tiers once, so both entry points read one predicate rather
  /// than two copies that can drift apart into a weaker gate.
  ///
  /// Unconditional scanning blocks on every egress class. The trifecta condition is
  /// tainted(session ∪ run) && privateData(assembly ∪ run ∪ session) — the session flag survives a
  /// window roll, closing the over-cap gap the per-assembly leg cannot. When it holds, conditional
  /// scanning runs and a redaction block WINS over approval; the private files are read from disk at
  /// gate time.
  func scanArguments(call: ToolCall, context: ToolDispatchContext) -> ArgumentScan {
    let unconditional = argGuard.evaluateUnconditional(argsJSON: call.argumentsJSON)
    if let rule = unconditional.blockedRule {
      return .blocked(blockedArgs(rule: rule, argsRedacted: unconditional.redactedArgs))
    }

    let tainted = context.sessionTainted || context.runIngestedUntrusted
    let privateData =
      context.assemblyPrivateData || context.runPrivateData || context.sessionHasPrivateData
    guard tainted && privateData else {
      return .cleared(argsRedacted: unconditional.redactedArgs, trifectaHeld: false)
    }

    let conditional = argGuard.evaluateConditional(
      argsJSON: call.argumentsJSON,
      privateFileTexts: privateFileLoader()
    )
    if let rule = conditional.blockedRule {
      return .blocked(blockedArgs(rule: rule, argsRedacted: conditional.redactedArgs))
    }
    return .cleared(argsRedacted: conditional.redactedArgs, trifectaHeld: true)
  }
}

// MARK: - Trifecta Verdicts

private extension ToolPolicyGate {
  /// The no-trifecta path: the action still resolves (or fails closed) so the dispatcher gets the
  /// gate-authorized canonical target, but no approval parks.
  func resolveAndAllow(call: ToolCall, tool: any Tool, argsRedacted: String) -> Verdict {
    switch resolveAction(call: call, tool: tool) {
    case .action(let action):
      return .allow(argsRedacted: argsRedacted, action: action)
    case .blocked(let payload):
      return .block(payload: payload, argsRedacted: argsRedacted)
    }
  }
}

// MARK: - Ask-tier approval

private extension ToolPolicyGate {
  /// An ask-tier tool MUST resolve a canonical target regardless of egress class —
  /// the approval binds to the resolved form. Malformed args or a `.refused` resolution block as
  /// they do for web_fetch; a `nil` resolution is a contract violation and fails CLOSED.
  func evaluateAskTier(call: ToolCall, tool: any Tool, context: ToolDispatchContext) -> Verdict {
    let argsRedacted: String
    if tool.definition.egressClass == .none {
      argsRedacted = argGuard.renderRedacted(argsJSON: call.argumentsJSON)
    } else {
      // Ask-tier parks on the approval fabric whether or not the trifecta holds, so only the
      // redaction matters here.
      switch scanArguments(call: call, context: context) {
      case .blocked(let verdict):
        return verdict
      case .cleared(let redacted, _):
        argsRedacted = redacted
      }
    }

    guard let arguments = JSONValue.parse(call.argumentsJSON) else {
      return askTierBlock(
        reason: "Malformed arguments for \(call.name).",
        argsRedacted: argsRedacted
      )
    }

    let target: String
    switch tool.canonicalTarget(arguments: arguments) {
    case .resolved(let resolved):
      target = resolved
    case .refused(let reason):
      return askTierBlock(reason: reason, argsRedacted: argsRedacted)
    case nil:
      return askTierBlock(
        reason: "\(call.name) is ask-tier but resolved no canonical target.",
        argsRedacted: argsRedacted
      )
    }

    if context.mode == .group {
      return groupAskTierVerdict(call: call, tool: tool, target: target, argsRedacted: argsRedacted)
    }

    // The run holds one approval slot: a further ask-tier call while one is pending gets the
    // blocked observation, never a second park.
    guard context.approvalAlreadyPending == false else {
      return pendingApprovalBlock(argsRedacted: argsRedacted)
    }

    let recorded = recordedAction(call: call, tool: tool, target: target, reason: .askTier)
    return .requireApproval(recorded: recorded)
  }

  /// Records the trifecta action as well as the ask-tier one. Canonicalizes
  /// the call arguments to sorted-keys JSON, hashes via `ApprovalArgsHash`, and asks the tool for
  /// its presentation on the gate-resolved target.
  func recordedAction(
    call: ToolCall,
    tool: any Tool,
    target: String,
    reason: ApprovalReason
  ) -> RecordedToolAction {
    let canonicalArgsJSON = Self.canonicalArgs(call.argumentsJSON)
    let presentation: ToolApprovalPresentation

    if let arguments = JSONValue.parse(call.argumentsJSON) {
      presentation = tool.approvalPresentation(arguments: arguments, canonicalTarget: target)
    } else {
      presentation = ToolApprovalPresentation(
        blastRadius: "egress to \(target)",
        contentPreview: nil,
        warnings: []
      )
    }

    return RecordedToolAction(
      tool: call.name,
      canonicalArgsJSON: canonicalArgsJSON,
      argsHash: ApprovalArgsHash.sha256Hex(canonicalArgsJSON),
      canonicalTarget: target,
      reason: reason,
      presentation: presentation
    )
  }

  /// Group mode has no approval banner, so the two things the banner used to catch are refused
  /// here instead: a tool whose real work only ever happens on the approval waiter, and a write
  /// that would rewrite a prompt file steering every later turn for everyone in the topic.
  /// Everything else executes on the gate-resolved target, which its `execute` requires.
  func groupAskTierVerdict(
    call: ToolCall,
    tool: any Tool,
    target: String,
    argsRedacted: String
  ) -> Verdict {
    guard tool.executesOnlyViaApproval == false else {
      return askTierBlock(
        reason:
          "\(call.name) needs the owner's approval, which a group chat has no way to ask for.",
        argsRedacted: argsRedacted
      )
    }

    let basename = (target as NSString).lastPathComponent
    guard WorkspaceFile.isPromptPrivileged(basename: basename) == false else {
      return askTierBlock(
        reason: "I don't rewrite \(basename) from a group chat — it steers every later turn.",
        argsRedacted: argsRedacted
      )
    }

    return .allow(argsRedacted: argsRedacted, action: ToolAction(tool: call.name, target: target))
  }

  func askTierBlock(reason: String, argsRedacted: String) -> Verdict {
    .block(
      payload: ToolPayload(content: reason, status: .error, ingestedUntrusted: false),
      argsRedacted: argsRedacted
    )
  }

  func pendingApprovalBlock(argsRedacted: String) -> Verdict {
    .block(
      payload: ToolPayload(
        content: "blocked: an approval is already pending",
        status: .blockedPendingApproval,
        ingestedUntrusted: false
      ),
      argsRedacted: argsRedacted
    )
  }

  /// Deterministic sorted-keys re-encoding so the same arguments always hash the same. Falls back
  /// to the raw string only if it is unparseable (the ask-tier path already blocks that case).
  static func canonicalArgs(_ rawArgumentsJSON: String) -> String {
    JSONValue.parse(rawArgumentsJSON).flatMap(CanonicalJSON.encode) ?? rawArgumentsJSON
  }
}

// MARK: - Dangerous-tier Approval

private extension ToolPolicyGate {
  /// Dangerous tools park ONLY over a tool-prepared canonical action. The `enabledDangerousTools` backstop
  /// fails closed; the arg-guard scans run over the prepared `guardTexts` (never the model's raw
  /// arguments), and the recorded action binds the prepared canonical JSON verbatim.
  func evaluateDangerousTier(
    call: ToolCall,
    tool: any Tool,
    context: ToolDispatchContext
  ) async -> Verdict {
    guard enabledDangerousTools.contains(tool.definition.name) else {
      return dangerousBlock(reason: "\(tool.definition.name) is disabled.", call: call)
    }
    // A dangerous action can never take the second approval slot, and it cannot park or execute
    // while one is pending, so refuse here before the expensive staging and content scans run.
    guard context.approvalAlreadyPending == false else {
      return pendingApprovalBlock(
        argsRedacted: argGuard.renderRedacted(argsJSON: call.argumentsJSON)
      )
    }
    guard let arguments = JSONValue.parse(call.argumentsJSON) else {
      return dangerousBlock(reason: "Malformed arguments for \(call.name).", call: call)
    }

    let actionResolution = await tool.prepareAction(arguments: arguments)
    guard let actionResolution else {
      return dangerousBlock(
        reason: "\(call.name) is dangerous-tier but prepared no action.",
        call: call
      )
    }

    let prepared: PreparedToolAction
    switch actionResolution {
    case .prepared(let action):
      prepared = action
    case .refused(let reason):
      return dangerousBlock(reason: reason, call: call)
    }

    for text in prepared.guardTexts {
      let verdict = argGuard.evaluate(text: text)
      if let rule = verdict.blockedRule {
        return blockedArgs(rule: rule, argsRedacted: "[REDACTED:\(rule)]")
      }
    }

    // The disk-time private-substring scan runs only when the prepared action can leave the host.
    if prepared.canExfiltrate {
      let privateIndex = ExfilArgGuard.PrivateTextIndex(texts: privateFileLoader())
      for text in prepared.guardTexts {
        let verdict = argGuard.evaluateConditional(text: text, index: privateIndex)
        if let rule = verdict.blockedRule {
          return blockedArgs(rule: rule, argsRedacted: "[REDACTED:\(rule)]")
        }
      }
    }

    // Group auto-run applies only to tools that do not require an explicit task confirmation.
    guard context.mode == .direct || tool.definition.requiresGroupApproval else {
      return .allow(
        argsRedacted: argGuard.renderRedacted(argsJSON: prepared.canonicalArgsJSON),
        action: ToolAction(tool: call.name, target: prepared.canonicalTarget),
        preparedArgsJSON: prepared.canonicalArgsJSON
      )
    }

    let recorded = RecordedToolAction(
      tool: call.name,
      canonicalArgsJSON: prepared.canonicalArgsJSON,
      argsHash: ApprovalArgsHash.sha256Hex(prepared.canonicalArgsJSON),
      canonicalTarget: prepared.canonicalTarget,
      reason: prepared.approvalReason,
      presentation: prepared.presentation
    )
    return .requireApproval(recorded: recorded)
  }

  func dangerousBlock(reason: String, call: ToolCall) -> Verdict {
    .block(
      payload: ToolPayload(content: reason, status: .error, ingestedUntrusted: false),
      argsRedacted: argGuard.renderRedacted(argsJSON: call.argumentsJSON)
    )
  }
}
