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
    guard tool.definition.egressClass != .none else {
      return .allow(
        argsRedacted: argGuard.renderRedacted(argsJSON: call.argumentsJSON),
        consumedGrant: false,
        action: nil
      )
    }

    // (2) unconditional tier — BLOCKING per FR-T6, every egress class
    let unconditional = argGuard.evaluateUnconditional(argsJSON: call.argumentsJSON)
    if let rule = unconditional.blockedRule {
      return blockedArgs(rule: rule, argsRedacted: unconditional.redactedArgs)
    }

    // (3) trifecta condition: tainted(session ∪ run) && privateData(assembly ∪ run)  [rev.1 H1]
    let tainted = context.sessionTainted || context.runIngestedUntrusted
    let privateData = context.assemblyPrivateData || context.runPrivateData
    guard tainted && privateData else {
      switch resolveAction(call: call, tool: tool) {
      case .action(let action):
        return .allow(
          argsRedacted: unconditional.redactedArgs,
          consumedGrant: false,
          action: action
        )
      case .blocked(let payload):
        return .block(
          payload: payload,
          argsRedacted: unconditional.redactedArgs,
          pendingApproval: nil
        )
      }
    }

    // (3a) conditional tier — redaction-block WINS over approval (FR-T6); disk at gate time
    let conditional = argGuard.evaluateConditional(
      argsJSON: call.argumentsJSON,
      privateFileTexts: privateFileLoader()
    )
    if let rule = conditional.blockedRule {
      return blockedArgs(rule: rule, argsRedacted: conditional.redactedArgs)
    }

    // (3b) the arbitrary-destination egress class (§18-H): grant match or approval
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

    if context.grant?.action == action {
      return .allow(argsRedacted: conditional.redactedArgs, consumedGrant: true, action: action)
    }

    if context.nonInteractive {
      // §10 (D5): a non-interactive run never parks an approval — would-park becomes an
      // immediate audited DENY, surfaced in the delivered result as a plain-language note. No
      // pending entry ⇒ no dangling confirmation can bind to the owner's next unrelated "yes"
      // (§16 case 3).
      return .block(
        payload: ToolPayload(
          content: """
            skipped \(call.name) of \(action.target) — it needs your approval; \
            run it interactively.
            """,
          status: .error,
          ingestedUntrusted: false
        ),
        argsRedacted: conditional.redactedArgs,
        pendingApproval: nil
      )
    }

    return .block(
      payload: ToolPayload(
        content: """
          BLOCKED_PENDING_APPROVAL: this fetch needs the owner's approval because \
          this session has read external content and holds private data. \
          Explain briefly why you want to fetch it and finish your reply.
          """,
        status: .blockedPendingApproval,
        ingestedUntrusted: false
      ),
      argsRedacted: conditional.redactedArgs,
      pendingApproval: context.approvalAlreadyPending
        ? nil
        : ToolApprovalRequest(action: action, reason: .exfilTrifecta)
    )
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
