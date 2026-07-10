import ClawCore
import Foundation

/// Spec §9.1 steps (2)-(3): the unconditional arg-guard tier, the trifecta condition, the tier-3
/// disk-time substring check, and the web_fetch grant/approval decision. Pure — every input
/// arrives via the call/context; tier-3 texts via the injected loader (disk at gate time).
public struct ToolPolicyGate: Sendable {
  public enum Verdict: Sendable, Equatable {
    /// `action` is the gate-resolved canonical action for `.arbitraryDestination` tools — the
    /// dispatcher hands its target into `execute` so the tool acts on exactly the form the gate
    /// authorized; `nil` for the other classes.
    case allow(argsRedacted: String, consumedGrant: Bool, action: ToolAction?)
    case block(payload: ToolPayload, argsRedacted: String, pendingApproval: ToolApprovalRequest?)
    /// An ask-tier action (§4.3/§5.1) parked for the owner's durable approval. Carries the recorded
    /// canonical args the §5.3 suspend commit persists and the §6.3 resume replays.
    case requireApproval(recorded: RecordedToolAction)
  }

  private let argGuard: ExfilArgGuard
  private let privateFileLoader: @Sendable () -> [String]

  public init(argGuard: ExfilArgGuard, privateFileLoader: @escaping @Sendable () -> [String]) {
    self.argGuard = argGuard
    self.privateFileLoader = privateFileLoader
  }

  public func evaluate(
    call: ToolCall,
    tool: any Tool,
    context: ToolDispatchContext
  ) -> Verdict {
    // (1) ask-tier is evaluated FIRST, before the egress fast-path (§4.3/§5.1): an ask-tier tool
    // reaches the durable approval arm regardless of egress class — an ask-tier file_write has
    // egress `.none` yet must still park for the owner's decision.
    if tool.definition.riskLevel == .ask {
      return evaluateAskTier(call: call, tool: tool, context: context)
    }

    // (2) .none-egress fast path — a safe non-egress read (file_read): audit-render only.
    guard tool.definition.egressClass != .none else {
      return .allow(
        argsRedacted: argGuard.renderRedacted(argsJSON: call.argumentsJSON),
        consumedGrant: false,
        action: nil
      )
    }

    // (3) unconditional tier — BLOCKING per FR-T6, every egress class
    let unconditional = argGuard.evaluateUnconditional(argsJSON: call.argumentsJSON)
    if let rule = unconditional.blockedRule {
      return blockedArgs(rule: rule, argsRedacted: unconditional.redactedArgs)
    }

    // (4) trifecta condition: tainted(session ∪ run) && privateData(assembly ∪ run ∪ session)
    let tainted = context.sessionTainted || context.runIngestedUntrusted
    // §4.5/§5.1: three private-data sources — the per-assembly leg, the run-local leg, and the
    // persisted session flag that survives a window roll (the §12 over-cap gap).
    let privateData =
      context.assemblyPrivateData || context.runPrivateData || context.sessionHasPrivateData
    guard tainted && privateData else {
      return resolveAndAllow(call: call, tool: tool, argsRedacted: unconditional.redactedArgs)
    }

    // (4a) conditional tier — redaction-block WINS over approval (FR-T6); disk at gate time
    let conditional = argGuard.evaluateConditional(
      argsJSON: call.argumentsJSON,
      privateFileTexts: privateFileLoader()
    )
    if let rule = conditional.blockedRule {
      return blockedArgs(rule: rule, argsRedacted: conditional.redactedArgs)
    }

    // (5) trifecta arm — DURABLE (§5.1/§8.3): a would-park action suspends onto the approval
    // fabric via `.requireApproval`. Non-interactive runs take the SAME park (→ EXPIRED → DENY),
    // never an immediate gate DENY. Recorded-args execution subsumes the retired one-turn grant.
    let action: ToolAction?
    switch resolveAction(call: call, tool: tool) {
    case .action(let resolved):
      action = resolved
    case .blocked(let payload):
      return .block(payload: payload, argsRedacted: conditional.redactedArgs, pendingApproval: nil)
    }
    guard let action else {
      return .allow(argsRedacted: conditional.redactedArgs, consumedGrant: false, action: nil)
    }

    guard context.approvalAlreadyPending == false else {
      // §5.2: one pending approval per run — a further gated call observes the block, never a
      // second suspend.
      return .block(
        payload: ToolPayload(
          content: "blocked: an approval is already pending",
          status: .blockedPendingApproval,
          ingestedUntrusted: false
        ),
        argsRedacted: conditional.redactedArgs,
        pendingApproval: nil
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

  /// The §9.1 audit rendering, exposed so the dispatcher's pre-gate error paths (unknown tool,
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
        // Names the rule CLASS, never the matched text (§9.1)
        content: "Blocked: the arguments matched the \(rule) rule and were not sent anywhere.",
        status: .blockedArgs,
        ingestedUntrusted: false
      ),
      argsRedacted: argsRedacted,
      pendingApproval: nil
    )
  }
}

// MARK: - Trifecta Verdicts

private extension ToolPolicyGate {
  /// The no-trifecta path: the action still resolves (or fails closed) so the dispatcher gets the
  /// gate-authorized canonical target, but no grant is consumed and no approval parks.
  func resolveAndAllow(call: ToolCall, tool: any Tool, argsRedacted: String) -> Verdict {
    switch resolveAction(call: call, tool: tool) {
    case .action(let action):
      return .allow(argsRedacted: argsRedacted, consumedGrant: false, action: action)
    case .blocked(let payload):
      return .block(payload: payload, argsRedacted: argsRedacted, pendingApproval: nil)
    }
  }
}

// MARK: - Ask-tier approval

private extension ToolPolicyGate {
  /// §4.3/§5.1(a): an ask-tier tool MUST resolve a canonical target regardless of egress class —
  /// the approval binds to the resolved form. Malformed args or a `.refused` resolution block as
  /// they do for web_fetch; a `nil` resolution is a contract violation and fails CLOSED.
  func evaluateAskTier(
    call: ToolCall,
    tool: any Tool,
    context: ToolDispatchContext
  ) -> Verdict {
    guard let arguments = JSONValue.parse(call.argumentsJSON) else {
      return askTierBlock(reason: "Malformed arguments for \(call.name).", call: call)
    }

    let target: String
    switch tool.canonicalTarget(arguments: arguments) {
    case .resolved(let resolved):
      target = resolved
    case .refused(let reason):
      return askTierBlock(reason: reason, call: call)
    case nil:
      return askTierBlock(
        reason: "\(call.name) is ask-tier but resolved no canonical target.",
        call: call
      )
    }

    // The run holds one approval slot (§5.2): a further ask-tier call while one is pending gets the
    // blocked observation, never a second park.
    guard context.approvalAlreadyPending == false else {
      return .block(
        payload: ToolPayload(
          content: "blocked: an approval is already pending",
          status: .blockedPendingApproval,
          ingestedUntrusted: false
        ),
        argsRedacted: argGuard.renderRedacted(argsJSON: call.argumentsJSON),
        pendingApproval: nil
      )
    }

    let recorded = recordedAction(call: call, tool: tool, target: target, reason: .askTier)
    return .requireApproval(recorded: recorded)
  }

  /// Phase 4 Task 23 (assumption A1) reuses this to record the trifecta action too. Canonicalizes
  /// the call arguments to sorted-keys JSON, hashes via `ApprovalArgsHash`, and asks the tool for
  /// its §5.4 presentation on the gate-resolved target.
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

  func askTierBlock(reason: String, call: ToolCall) -> Verdict {
    .block(
      payload: ToolPayload(content: reason, status: .error, ingestedUntrusted: false),
      argsRedacted: argGuard.renderRedacted(argsJSON: call.argumentsJSON),
      pendingApproval: nil
    )
  }

  /// Deterministic sorted-keys re-encoding so the same arguments always hash the same. Falls back
  /// to the raw string only if it is unparseable (the ask-tier path already blocks that case).
  static func canonicalArgs(_ rawArgumentsJSON: String) -> String {
    guard let value = JSONValue.parse(rawArgumentsJSON) else {
      return rawArgumentsJSON
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    guard
      let data = try? encoder.encode(value),
      let json = String(data: data, encoding: .utf8)
    else {
      return rawArgumentsJSON
    }

    return json
  }
}

/// §9.1's full per-call order behind the loop's `ToolDispatching` seam: (0) lookup → (1) parse →
/// (2)/(3) gate → (4) execute under the tool's own timeout. Audit is the LOOP's job (§6).
public struct GatedToolDispatcher: ToolDispatching {
  private let registry: ToolRegistry
  private let gate: ToolPolicyGate
  /// Injected so tests drive the timeout race deterministically (same seam as `AgentRuntime`).
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    registry: ToolRegistry,
    gate: ToolPolicyGate,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.registry = registry
    self.gate = gate
    self.sleep = sleep
  }

  public var definitions: [ToolDefinition] {
    registry.definitions
  }

  /// The same name-keyed catalog `dispatch` gates through, surfaced so Task 16's composition root
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
    switch gate.evaluate(call: call, tool: tool, context: context) {
    case .block(let payload, let argsRedacted, let pendingApproval):
      return ToolDispatchOutcome(
        observation: ToolObservation(call: call, payload: payload),
        argsRedacted: argsRedacted,
        pendingApproval: pendingApproval
      )
    case .requireApproval(let recorded):
      // The recorded action rides the outcome to the loop (Task 12), which sets the pending action
      // and returns `.suspended`. The observation is the placeholder the §5.3 suspend commit
      // persists in place and updates at resolution — the pending call itself does not execute now.
      return ToolDispatchOutcome(
        observation: ToolObservation(
          callId: call.id,
          toolName: call.name,
          content: "awaiting owner approval",
          status: .blockedPendingApproval,
          ingestedUntrusted: false
        ),
        argsRedacted: gate.renderRedacted(argsJSON: call.argumentsJSON),
        requiresApproval: recorded
      )
    case .allow(let argsRedacted, let consumedGrant, let action):
      // (4) execute under the tool's own timeout, on the gate-resolved canonical target
      let payload = await executeWithTimeout(
        tool: tool,
        arguments: arguments,
        canonicalTarget: action?.target
      )
      return ToolDispatchOutcome(
        observation: ToolObservation(call: call, payload: payload),
        argsRedacted: argsRedacted,
        consumedGrant: consumedGrant
      )
    }
  }

  /// First finisher wins and the LOSER IS ABANDONED, never awaited: a task group always awaits
  /// its children (the pitfall `sendDraftBounded` documents), so a wedged tool — a blocking
  /// syscall, hung I/O — would otherwise hold the strict-FIFO session lane hostage far past its
  /// declared timeout, beyond `/stop`'s reach. The abandoned execute task keeps running detached
  /// until its I/O returns; today's tools are read-only, so a post-timeout side effect is
  /// harmless — Inc 5's write tools must revisit this contract explicitly.
  private func executeWithTimeout(
    tool: any Tool,
    arguments: JSONValue,
    canonicalTarget: String?
  ) async -> ToolPayload {
    let timeoutPayload = ToolPayload(
      content: "The \(tool.definition.name) call timed out.",
      status: .error,
      ingestedUntrusted: false
    )

    let firstResult = AsyncStream<ToolPayload> { continuation in
      let executeTask = Task {
        continuation.yield(
          await tool.execute(arguments: arguments, canonicalTarget: canonicalTarget)
        )
        continuation.finish()
      }
      let timeoutTask = Task { [sleep] in
        try? await sleep(tool.timeout)
        continuation.yield(timeoutPayload)
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in
        executeTask.cancel()
        timeoutTask.cancel()
      }
    }

    for await payload in firstResult {
      return payload
    }
    return timeoutPayload
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
