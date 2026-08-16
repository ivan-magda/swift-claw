import ClawCore
import Foundation

/// The single policy gate for safe, ask-tier, and dangerous tools. Safe egress retains the
/// unconditional/trifecta tiers; ask-tier actions resolve owner consent; dangerous actions may
/// park only after the tool prepares, scans, and binds the exact recorded action.
public struct ToolPolicyGate: Sendable {
  public enum Verdict: Sendable, Equatable {
    /// `action` is the gate-resolved canonical action for `.arbitraryDestination` tools — the
    /// dispatcher hands its target into `execute` so the tool acts on exactly the form the gate
    /// authorized; `nil` for the other classes.
    case allow(argsRedacted: String, action: ToolAction?)
    case block(payload: ToolPayload, argsRedacted: String)
    /// An ask-tier action parked for the owner's durable approval. Carries the recorded
    /// canonical args the suspend commit persists and the resume replays.
    case requireApproval(recorded: RecordedToolAction)
  }

  private let argGuard: ExfilArgGuard
  private let privateFileLoader: @Sendable () -> [String]
  private let execEnabled: Bool

  public init(
    argGuard: ExfilArgGuard,
    privateFileLoader: @escaping @Sendable () -> [String],
    execEnabled: Bool
  ) {
    self.argGuard = argGuard
    self.privateFileLoader = privateFileLoader
    self.execEnabled = execEnabled
  }

  public func evaluate(
    call: ToolCall,
    tool: any Tool,
    context: ToolDispatchContext
  ) async -> Verdict {
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
      guard trifectaHeld else {
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
      return .block(
        payload: ToolPayload(
          content: "blocked: an approval is already pending",
          status: .blockedPendingApproval,
          ingestedUntrusted: false
        ),
        argsRedacted: argsRedacted
      )
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
  func evaluateAskTier(
    call: ToolCall,
    tool: any Tool,
    context: ToolDispatchContext
  ) -> Verdict {
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

    // The run holds one approval slot: a further ask-tier call while one is pending gets the
    // blocked observation, never a second park.
    guard context.approvalAlreadyPending == false else {
      return .block(
        payload: ToolPayload(
          content: "blocked: an approval is already pending",
          status: .blockedPendingApproval,
          ingestedUntrusted: false
        ),
        argsRedacted: argsRedacted
      )
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

  func askTierBlock(reason: String, argsRedacted: String) -> Verdict {
    .block(
      payload: ToolPayload(content: reason, status: .error, ingestedUntrusted: false),
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
  /// Dangerous tools park ONLY over a tool-prepared canonical action. The `execEnabled` backstop
  /// fails closed; the arg-guard scans run over the prepared `guardTexts` (never the model's raw
  /// arguments), and the recorded action binds the prepared canonical JSON verbatim.
  func evaluateDangerousTier(
    call: ToolCall,
    tool: any Tool,
    context: ToolDispatchContext
  ) async -> Verdict {
    guard execEnabled else {
      return dangerousBlock(reason: "Code execution is disabled.", call: call)
    }
    // A dangerous action can never take the second approval slot, and it cannot park or execute
    // while one is pending, so refuse here before the expensive staging and content scans run.
    guard context.approvalAlreadyPending == false else {
      return .block(
        payload: ToolPayload(
          content: "blocked: an approval is already pending",
          status: .blockedPendingApproval,
          ingestedUntrusted: false
        ),
        argsRedacted: argGuard.renderRedacted(argsJSON: call.argumentsJSON)
      )
    }
    guard let arguments = JSONValue.parse(call.argumentsJSON) else {
      return dangerousBlock(reason: "Malformed arguments for \(call.name).", call: call)
    }
    guard let resolution = await tool.prepareAction(arguments: arguments) else {
      return dangerousBlock(
        reason: "\(call.name) is dangerous-tier but prepared no action.",
        call: call
      )
    }

    let prepared: PreparedToolAction
    switch resolution {
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

    let recorded = RecordedToolAction(
      tool: call.name,
      canonicalArgsJSON: prepared.canonicalArgsJSON,
      argsHash: ApprovalArgsHash.sha256Hex(prepared.canonicalArgsJSON),
      canonicalTarget: prepared.canonicalTarget,
      reason: .codeExec,
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

/// The full per-call order behind the loop's `ToolDispatching` seam: (0) lookup → (1) parse →
/// (2)/(3) gate → (4) execute under the tool's own timeout. Audit is the LOOP's job.
public struct GatedToolDispatcher: ToolDispatching {
  private let registry: ToolRegistry
  private let gate: ToolPolicyGate
  /// Injected so tests drive the timeout race deterministically (same seam as `AgentRuntime`).
  private let clock: any Clock<Duration>

  public init(
    registry: ToolRegistry,
    gate: ToolPolicyGate,
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.registry = registry
    self.gate = gate
    self.clock = clock
  }

  public var definitions: [ToolDefinition] {
    registry.definitions
  }

  /// The same name-keyed catalog `dispatch` gates through, surfaced so the composition root
  /// can build `ApprovedActionExecutor` against the identical tool instances.
  public var toolsByName: [String: any Tool] {
    registry.toolsByName
  }

  public func dispatch(call: ToolCall, context: ToolDispatchContext) async -> ToolDispatchOutcome {
    // (0) unknown tool → error observation, never a crash
    guard let tool = registry.tool(named: call.name) else {
      return errorOutcome(call: call, reason: "Unknown tool \(call.name).")
    }
    // (1) malformed argumentsJSON → error observation
    guard let arguments = JSONValue.parse(call.argumentsJSON) else {
      return errorOutcome(call: call, reason: "Malformed arguments for \(call.name).")
    }
    // (2)/(3) the gate
    switch await gate.evaluate(call: call, tool: tool, context: context) {
    case .block(let payload, let argsRedacted):
      return ToolDispatchOutcome(
        observation: ToolObservation(call: call, payload: payload),
        argsRedacted: argsRedacted
      )
    case .requireApproval(let recorded):
      // The recorded action rides the outcome to the loop, which sets the pending action
      // and returns `.suspended`. The observation is the placeholder the suspend commit
      // persists in place and updates at resolution — the pending call itself does not execute now.
      return ToolDispatchOutcome(
        observation: ToolObservation(
          callId: call.id,
          toolName: call.name,
          content: "awaiting owner approval",
          status: .blockedPendingApproval,
          ingestedUntrusted: false
        ),
        argsRedacted: gate.renderRedacted(argsJSON: recorded.canonicalArgsJSON),
        requiresApproval: recorded
      )
    case .allow(let argsRedacted, let action):
      // (4) execute under the tool's own timeout, on the gate-resolved canonical target
      let payload = await executeWithTimeout(
        tool: tool,
        arguments: arguments,
        canonicalTarget: action?.target
      )
      return ToolDispatchOutcome(
        observation: ToolObservation(call: call, payload: payload),
        argsRedacted: argsRedacted
      )
    }
  }

  /// Bounded by the shared `DeadlineRace`, whose loser is cancelled and ABANDONED, never
  /// awaited: a task group always awaits its children (the pitfall `sendDraftBounded`
  /// documents), so a wedged tool — a blocking syscall, hung I/O — would otherwise hold the
  /// strict-FIFO session lane hostage far past its declared timeout, beyond `/stop`'s reach.
  /// The abandoned execute task keeps running detached until its I/O returns; today's tools are
  /// read-only, so a post-timeout side effect is harmless — write tools must revisit this
  /// contract explicitly.
  private func executeWithTimeout(
    tool: any Tool,
    arguments: JSONValue,
    canonicalTarget: String?
  ) async -> ToolPayload {
    let outcome = await DeadlineRace.race(
      allowance: tool.timeout,
      sleep: { [clock] duration in
        try await clock.sleep(for: duration)
      },
      operation: {
        await tool.execute(arguments: arguments, canonicalTarget: canonicalTarget)
      }
    )

    switch outcome {
    case .operationReturned(let payload):
      return payload
    case .deadlineExpired, .callerCancelled:
      return ToolPayload(
        content: "The \(tool.definition.name) call timed out.",
        status: .error,
        ingestedUntrusted: false
      )
    }
  }

  private func errorOutcome(call: ToolCall, reason: String) -> ToolDispatchOutcome {
    ToolDispatchOutcome(
      observation: ToolObservation(
        callId: call.id,
        toolName: call.name,
        content: reason,
        status: .error,
        ingestedUntrusted: false
      ),
      argsRedacted: gate.renderRedacted(argsJSON: call.argumentsJSON)
    )
  }
}
