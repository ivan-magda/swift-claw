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
    /// a group topic allowed a dangerous action outright. `execute` decodes that recorded shape,
    /// not the model's raw arguments, so the dispatcher must hand it over verbatim.
    case allow(argsRedacted: String, action: ToolAction?, preparedArgsJSON: String? = nil)
    /// A dangerous action the run's open turn-scoped window already authorized: it runs now, on
    /// the canonical args the tool prepared and the guards scanned, never on the model's raw ones.
    /// Separate from `.allow` because a windowed tool acts on the host, so the dispatcher awaits
    /// it to completion instead of abandoning it on the generic deadline race.
    case allowPrepared(recorded: RecordedToolAction, argsRedacted: String)
    case block(payload: ToolPayload, argsRedacted: String)
    /// An ask-tier action parked for the owner's durable approval. Carries the recorded
    /// canonical args the suspend commit persists and the resume replays.
    case requireApproval(recorded: RecordedToolAction)
  }

  private let argGuard: ExfilArgGuard
  private let privateFileLoader: @Sendable () -> [String]
  /// One switch per dangerous tool, keyed by tool name: the owner enables host execution and the
  /// sandbox independently, so neither config flag can turn the other tool on.
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
    if let refusal = ownerAbsentRefusal(call: call, tool: tool, context: context) {
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

// MARK: - Owner Presence

private extension ToolPolicyGate {
  /// A tool that acts only under the owner's eye is refused outright wherever the owner is not
  /// there to watch. A proactive run would leave a host action queued against an owner who is not
  /// reading; a group topic is served to people who are not the owner at all, and its dangerous
  /// tier runs untapped, so the refusal is the only thing standing between an attendee and the
  /// host.
  func ownerAbsentRefusal(
    call: ToolCall,
    tool: any Tool,
    context: ToolDispatchContext
  ) -> Verdict? {
    guard tool.definition.requiresInteractiveRun, let absence = ownerAbsence(context) else {
      return nil
    }
    return .block(
      payload: ToolPayload(
        content:
          "\(tool.definition.name) is unavailable in \(absence): "
          + "it runs only while the owner is present.",
        status: .error,
        ingestedUntrusted: false
      ),
      argsRedacted: argGuard.renderRedacted(argsJSON: call.argumentsJSON)
    )
  }

  /// Where the run leaves the owner unable to watch it, phrased for the refusal; nil when the
  /// owner is the one at the other end.
  func ownerAbsence(_ context: ToolDispatchContext) -> String? {
    if context.runOrigin.isProactive {
      return "a \(context.runOrigin.rawValue) run"
    }
    return context.mode == .group ? "a group chat" : nil
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

    if context.mode == .group {
      return groupAskTierVerdict(
        call: call,
        tool: tool,
        target: target,
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

    return .allow(
      argsRedacted: argsRedacted,
      action: ToolAction(tool: call.name, target: target)
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
  /// Dangerous tools park ONLY over a tool-prepared canonical action. The per-tool backstop
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

    if let blocked = scanPrepared(prepared) {
      return blocked
    }

    let recorded = RecordedToolAction(
      tool: call.name,
      canonicalArgsJSON: prepared.canonicalArgsJSON,
      argsHash: ApprovalArgsHash.sha256Hex(prepared.canonicalArgsJSON),
      canonicalTarget: prepared.canonicalTarget,
      reason: prepared.approvalReason,
      presentation: prepared.presentation
    )

    // A group topic has nobody to press the button, so the prepared action runs untapped — the
    // sandbox is the containment, not a prompt. It stays on the bounded execution path: a tool
    // that must not be abandoned mid-flight declares `requiresInteractiveRun` and was refused
    // upstream, so only a disposable sandbox reaches here.
    guard context.mode == .direct else {
      return .allow(
        argsRedacted: argGuard.renderRedacted(argsJSON: prepared.canonicalArgsJSON),
        action: ToolAction(tool: call.name, target: prepared.canonicalTarget),
        preparedArgsJSON: prepared.canonicalArgsJSON
      )
    }

    // The window widens only the reason the owner was offered it on, and only past the scans
    // above: the guards run on a window-approved command exactly as they do on a parked one.
    guard context.autoApproveWindowOpen, prepared.approvalReason.offersTurnScopedWindow else {
      return .requireApproval(recorded: recorded)
    }
    return .allowPrepared(
      recorded: recorded,
      argsRedacted: argGuard.renderRedacted(argsJSON: prepared.canonicalArgsJSON)
    )
  }

  /// The arg-guard pass over what the tool actually prepared, never the model's raw arguments —
  /// the dangerous-tier counterpart to `scanArguments`. Nil clears the action to proceed.
  func scanPrepared(_ prepared: PreparedToolAction) -> Verdict? {
    for text in prepared.guardTexts {
      let verdict = argGuard.evaluate(text: text)
      if let rule = verdict.blockedRule {
        return blockedArgs(rule: rule, argsRedacted: "[REDACTED:\(rule)]")
      }
    }

    // The disk-time private-substring scan runs only when the prepared action can leave the host.
    guard prepared.canExfiltrate else {
      return nil
    }
    let privateIndex = ExfilArgGuard.PrivateTextIndex(texts: privateFileLoader())
    for text in prepared.guardTexts {
      let verdict = argGuard.evaluateConditional(text: text, index: privateIndex)
      if let rule = verdict.blockedRule {
        return blockedArgs(rule: rule, argsRedacted: "[REDACTED:\(rule)]")
      }
    }
    return nil
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
  /// Announces a call the gate cleared, before it runs. Absent wherever nothing delivers to the
  /// owner (a probe, a test); a tool that declares an announcement then fails its call rather
  /// than acting unannounced, so the owner never misses a command that ran.
  private let echo: (any ToolInvocationEchoing)?

  public init(
    registry: ToolRegistry,
    gate: ToolPolicyGate,
    clock: any Clock<Duration> = ContinuousClock(),
    echo: (any ToolInvocationEchoing)? = nil
  ) {
    self.registry = registry
    self.gate = gate
    self.clock = clock
    self.echo = echo
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
    let verdict = await gate.evaluate(call: call, tool: tool, context: context)
    guard Task.isCancelled == false else { return cancellationOutcome(call: call) }
    switch verdict {
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
    case .allowPrepared(let recorded, let argsRedacted):
      return await runWindowed(
        call: call,
        tool: tool,
        recorded: recorded,
        argsRedacted: argsRedacted,
        context: context
      )
    case .allow(let argsRedacted, let action, let preparedArgsJSON):
      // (4) execute under the tool's own timeout, on the gate-resolved canonical target. A
      // dangerous action a group topic allowed outright runs its prepared canonical args, and the
      // announcement resolves from the same value, so the owner never reads one command while
      // another one runs.
      guard let executed = executedArguments(raw: arguments, prepared: preparedArgsJSON) else {
        return errorOutcome(call: call, reason: "The prepared \(call.name) action is unreadable.")
      }
      guard await announce(tool: tool, arguments: executed, context: context) else {
        return announcementFailureOutcome(call: call)
      }
      guard Task.isCancelled == false else {
        return cancellationOutcome(call: call)
      }
      let payload = await executeWithTimeout(
        tool: tool,
        arguments: executed,
        canonicalTarget: action?.target
      )
      return ToolDispatchOutcome(
        observation: ToolObservation(call: call, payload: payload),
        argsRedacted: argsRedacted
      )
    }
  }

  /// What `execute` receives: the prepared canonical arguments when the gate allowed a dangerous
  /// action outright, the model's own otherwise. Nil when the recorded form no longer parses.
  private func executedArguments(raw: JSONValue, prepared: String?) -> JSONValue? {
    guard let prepared else {
      return raw
    }
    return JSONValue.parse(prepared)
  }

  /// (4) the same execution an approval resume would replay: the recorded canonical args on the
  /// recorded target, so a widened call and an approved one act on identical inputs. Awaited and
  /// never raced — a turn-scoped window is the one way a host-acting tool executes without an
  /// approval, and its side effects must stay owned until its own bounded teardown has completed.
  private func runWindowed(
    call: ToolCall,
    tool: any Tool,
    recorded: RecordedToolAction,
    argsRedacted: String,
    context: ToolDispatchContext
  ) async -> ToolDispatchOutcome {
    guard let preparedArguments = JSONValue.parse(recorded.canonicalArgsJSON) else {
      return errorOutcome(call: call, reason: "The prepared \(call.name) action is unreadable.")
    }
    guard await announce(tool: tool, arguments: preparedArguments, context: context) else {
      return announcementFailureOutcome(call: call)
    }
    guard Task.isCancelled == false else {
      return cancellationOutcome(call: call)
    }
    let payload = await tool.execute(
      arguments: preparedArguments,
      canonicalTarget: recorded.canonicalTarget
    )
    return ToolDispatchOutcome(
      observation: ToolObservation(call: call, payload: payload),
      argsRedacted: argsRedacted
    )
  }

  /// The pre-execution announcement, on the exact arguments `execute` is about to receive. It
  /// sits after the gate and before the side effect, so a blocked or parked call is never
  /// announced and an announced one is always still interruptible.
  private func announce(
    tool: any Tool,
    arguments: JSONValue,
    context: ToolDispatchContext
  ) async -> Bool {
    guard let detail = tool.invocationEcho(arguments: arguments) else {
      return true
    }
    guard let echo else {
      return false
    }
    return await echo.echo(
      ToolInvocationEcho(
        runId: context.runId,
        chatId: context.chatId,
        tool: tool.definition.name,
        detail: detail
      )
    )
  }

  /// Bounded by the shared `DeadlineRace`, whose loser is cancelled and ABANDONED, never
  /// awaited: a task group always awaits its children (the pitfall `sendDraftBounded`
  /// documents), so a wedged tool — a blocking syscall, hung I/O — would otherwise hold the
  /// strict-FIFO session lane hostage far past its declared timeout, beyond `/stop`'s reach.
  /// The abandoned execute task keeps running detached until its I/O returns. A host-acting tool
  /// never reaches this race — it is awaited directly in `.allowPrepared`.
  ///
  /// A group turn dispatches write tools here, so the abandonment is no longer free — and it is
  /// still the right trade. `file_write` commits through a staged temp file and a single
  /// `rename(2)`/`link(2)`, so an abandoned write either lands whole or leaves the previous file
  /// untouched; there is no torn state to observe. `execute_code` runs inside a sandbox that
  /// enforces its own shorter timeout and tears itself down under a detached shield, and the
  /// dispatcher's allowance sits 20s above it, so the race fires only once the sandbox has
  /// already wedged — exactly the case worth abandoning, since the container FIFO lane is shared
  /// and a held turn would queue every other topic behind it. In both cases the turn observes a
  /// timeout, which may understate what happened; the alternative is a wedged tool holding the
  /// session lane, which is worse.
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

  private func cancellationOutcome(call: ToolCall) -> ToolDispatchOutcome {
    errorOutcome(call: call, reason: "The \(call.name) call was cancelled; nothing ran.")
  }

  private func announcementFailureOutcome(call: ToolCall) -> ToolDispatchOutcome {
    errorOutcome(
      call: call,
      reason: "The \(call.name) call could not be announced safely; nothing ran."
    )
  }
}
