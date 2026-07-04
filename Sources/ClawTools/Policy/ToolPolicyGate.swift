import ClawCore
import Foundation

/// Spec §9.1 steps (2)-(3): the unconditional arg-guard tier, the trifecta condition, the tier-3
/// disk-time substring check, and the web_fetch grant/approval decision. Pure — every input
/// arrives via the call/context; tier-3 texts via the injected loader (disk at gate time).
public struct ToolPolicyGate: Sendable {
  /// The outbound sinks the arg-guard tiers cover (§9.1 step 2 note, §18-H). `file_read` is not
  /// an egress sink; its args are only redaction-RENDERED for audit.
  static let egressTools: Set<String> = ["web_fetch", "web_search"]

  public enum Verdict: Sendable, Equatable {
    case allow(argsRedacted: String, consumedGrant: Bool)
    case block(payload: ToolPayload, argsRedacted: String, pendingApproval: ExfilApprovalRequest?)
  }

  private let argGuard: ExfilArgGuard
  private let privateFileLoader: @Sendable () -> [String]

  public init(argGuard: ExfilArgGuard, privateFileLoader: @escaping @Sendable () -> [String]) {
    self.argGuard = argGuard
    self.privateFileLoader = privateFileLoader
  }

  public func evaluate(call: ToolCall, context: ToolDispatchContext) -> Verdict {
    guard Self.egressTools.contains(call.name) else {
      return .allow(
        argsRedacted: argGuard.renderRedacted(argsJSON: call.argumentsJSON),
        consumedGrant: false
      )
    }

    // (2) unconditional tier — BLOCKING per FR-T6, fetch AND search
    let unconditional = argGuard.evaluateUnconditional(argsJSON: call.argumentsJSON)
    if let rule = unconditional.blockedRule {
      return blockedArgs(rule: rule, argsRedacted: unconditional.redactedArgs)
    }

    // (3) trifecta condition: tainted(session ∪ run) && privateData(assembly ∪ run)  [rev.1 H1]
    let tainted = context.sessionTainted || context.runIngestedUntrusted
    let privateData = context.assemblyPrivateData || context.runPrivateData
    guard tainted && privateData else {
      return .allow(argsRedacted: unconditional.redactedArgs, consumedGrant: false)
    }

    // (3a) conditional tier — redaction-block WINS over approval (FR-T6); disk at gate time
    let conditional = argGuard.evaluateConditional(
      argsJSON: call.argumentsJSON,
      privateFileTexts: privateFileLoader()
    )
    if let rule = conditional.blockedRule {
      return blockedArgs(rule: rule, argsRedacted: conditional.redactedArgs)
    }

    // (3b) web_fetch only — the arbitrary-destination egress class (§18-H)
    guard call.name == "web_fetch" else {
      return .allow(argsRedacted: conditional.redactedArgs, consumedGrant: false)
    }
    guard let rawURL = JSONValue.parse(call.argumentsJSON)?.objectValue?["url"]?.stringValue else {
      return .block(
        payload: ToolPayload(
          content: "web_fetch needs a \"url\" argument.",
          status: .error,
          ingestedUntrusted: false
        ),
        argsRedacted: conditional.redactedArgs,
        pendingApproval: nil
      )
    }
    let canonical: String
    switch CanonicalURL.canonicalize(rawURL) {
    case .success(let value):
      canonical = value
    case .failure:
      // URL-policy refusal BEFORE any prompt is built (§9.2 — userinfo/IDN/scheme/port)
      return .block(
        payload: ToolPayload(
          content:
            "That URL is not allowed (credentials, non-ASCII host, or unsupported scheme/port).",
          status: .error,
          ingestedUntrusted: false
        ),
        argsRedacted: conditional.redactedArgs,
        pendingApproval: nil
      )
    }

    if context.grant?.canonicalURL == canonical {
      return .allow(argsRedacted: conditional.redactedArgs, consumedGrant: true)
    }

    return .block(
      payload: ToolPayload(
        content:
          "BLOCKED_PENDING_APPROVAL: this fetch needs the owner's approval because this session has read external content and holds private data. Explain briefly why you want to fetch it and finish your reply.",
        status: .blockedPendingApproval,
        ingestedUntrusted: false
      ),
      argsRedacted: conditional.redactedArgs,
      pendingApproval: context.approvalAlreadyPending
        ? nil
        : ExfilApprovalRequest(canonicalURL: canonical)
    )
  }

  /// The §9.1 audit rendering, exposed so the dispatcher's pre-gate error paths (unknown tool,
  /// malformed args) can redact their args too — the `argsRedacted` seam field must never carry a
  /// raw secret, whatever the outcome.
  public func renderRedacted(argsJSON: String) -> String {
    argGuard.renderRedacted(argsJSON: argsJSON)
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

  public init(registry: ToolRegistry, gate: ToolPolicyGate) {
    self.registry = registry
    self.gate = gate
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
    switch gate.evaluate(call: call, context: context) {
    case .block(let payload, let argsRedacted, let pendingApproval):
      return ToolDispatchOutcome(
        observation: ToolObservation(call: call, payload: payload),
        argsRedacted: argsRedacted,
        pendingApproval: pendingApproval
      )
    case .allow(let argsRedacted, let consumedGrant):
      // (4) execute under the tool's own timeout
      let payload = await Self.executeWithTimeout(tool: tool, arguments: arguments)
      return ToolDispatchOutcome(
        observation: ToolObservation(call: call, payload: payload),
        argsRedacted: argsRedacted,
        consumedGrant: consumedGrant
      )
    }
  }

  /// First finisher wins: the tool's result or the timeout observation. The loser is cancelled.
  private static func executeWithTimeout(
    tool: any Tool,
    arguments: JSONValue
  ) async -> ToolPayload {
    await withTaskGroup(of: ToolPayload.self) { group in
      group.addTask {
        await tool.execute(arguments: arguments)
      }
      group.addTask {
        try? await Task.sleep(for: tool.timeout)
        return ToolPayload(
          content: "The \(tool.definition.name) call timed out.",
          status: .error,
          ingestedUntrusted: false
        )
      }
      let winner =
        await group.next()
        ?? ToolPayload(
          content: "The \(tool.definition.name) call produced no result.",
          status: .error,
          ingestedUntrusted: false
        )
      group.cancelAll()
      return winner
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
