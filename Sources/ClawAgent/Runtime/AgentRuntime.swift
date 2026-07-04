import ClawCore
import Foundation

/// Why a turn produced no usable answer. Maps to a plain-language degradation reply (§7); the
/// stable `rawValue` is what the audit log records, so it survives case renames.
public enum DegradationKind: String, Sendable, Equatable {
  case providerUnavailable
  case outputTruncated
  case contextUnavailable
  case accountingFailed  // NEW (§6 — usage-write failure mid-run)
}

/// The outcome of one orchestrated turn. `runTurn` never throws — every failure becomes one of
/// these so the gateway always has something to persist and send (never silence).
public enum TurnResult: Sendable, Equatable {
  /// A usable answer plus the reconciled, provider-truth usage to debit.
  case completed(content: String, usage: ProviderUsage)
  /// No usable answer. `usage` is the real row when the call returned (truncation) or an
  /// estimated row when it didn't (deadline / exhausted retries); `nil` for terminal errors.
  case degraded(DegradationKind, usage: ProviderUsage?)
  /// The offline budget gate refused before any provider call; `cap` names the tripped limit.
  case budgetStopped(cap: String)
}

/// The outcome of the bounded agentic loop (§6): the terminal `TurnResult` plus everything the
/// gateway needs to persist and gate the next turn.
public struct TurnOutcome: Sendable {
  public let result: TurnResult
  /// Every round-trip that proposed tool calls, to persist (§11).
  public let exchanges: [ToolExchange]
  /// Taint signal: any executed observation ingested untrusted content this run (§10).
  public let ingestedUntrusted: Bool
  /// A gate trip awaiting the owner's approval, if this run tripped one (§9).
  public let pendingApproval: ExfilApprovalRequest?

  public init(
    result: TurnResult,
    exchanges: [ToolExchange] = [],
    ingestedUntrusted: Bool = false,
    pendingApproval: ExfilApprovalRequest? = nil
  ) {
    self.result = result
    self.exchanges = exchanges
    self.ingestedUntrusted = ingestedUntrusted
    self.pendingApproval = pendingApproval
  }
}

/// The pure orchestration of one blocking turn: preflight → typing + wall-clock deadline →
/// provider call → classify. No persistence or sending (the gateway owns that in Task 5); all
/// collaborators are injected `ClawCore` protocols so tests drive it with mocks.
public struct AgentRuntime: Sendable {
  private let provider: any LLMProvider
  private let typingIndicator: any TypingIndicator
  private let draftStreamer: any RichDraftStreaming
  private let streamingEnabled: Bool
  private let costResolver: CostResolver
  private let usageResolver: UsageResolver
  private let budget: RunBudget
  private let model: String
  private let toolDispatcher: (any ToolDispatching)?
  private let usageStore: any UsageStore
  private let auditLog: any AuditLog
  private let warn: @Sendable (String) -> Void
  /// Injected so tests can make the deadline fire instantly with a no-op sleep.
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    provider: any LLMProvider,
    typingIndicator: any TypingIndicator,
    draftStreamer: any RichDraftStreaming,
    streamingEnabled: Bool,
    costResolver: CostResolver,
    usageResolver: UsageResolver = UsageResolver(),
    budget: RunBudget,
    model: String,
    toolDispatcher: (any ToolDispatching)? = nil,
    usageStore: any UsageStore,
    auditLog: any AuditLog,
    warn: @escaping @Sendable (String) -> Void = { _ in },
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.provider = provider
    self.typingIndicator = typingIndicator
    self.draftStreamer = draftStreamer
    self.streamingEnabled = streamingEnabled
    self.costResolver = costResolver
    self.usageResolver = usageResolver
    self.budget = budget
    self.model = model
    self.toolDispatcher = toolDispatcher
    self.usageStore = usageStore
    self.auditLog = auditLog
    self.warn = warn
    self.sleep = sleep
  }

  /// The bounded agentic loop (spec §6): one context assembly, then up to `maxTurns` round-trips
  /// with per-round-trip budget preflight, gated tool dispatch, and immediate usage/audit writes.
  /// DELIBERATE SOFTENING of Inc 1's "no persistence here": `usageStore`/`auditLog` are injected
  /// so mid-run rows survive a crash (D6/review H1). Throws ONLY `StoreError.diskFull`; every
  /// other failure resolves in-band to a `TurnResult`.
  // swiftlint:disable:next function_parameter_count function_body_length
  public func runTurn(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    buildResult: BuildResult,
    sessionTainted: Bool,
    fetchGrant: OneTurnFetchGrant?,
    todayTokens: Int,
    todayUSD: Double
  ) async throws -> TurnOutcome {
    let deadline = ContinuousClock.now + .seconds(budget.wallClockDeadlineSeconds)
    let definitions = toolDispatcher?.definitions ?? []
    let gate = BudgetGate(budget: budget)

    var wire = buildResult.messages
    var exchanges: [ToolExchange] = []
    var ingestedUntrusted = false
    var runPrivateData = false
    var pendingApproval: ExfilApprovalRequest?
    var grant = fetchGrant
    var proposedToolCalls = 0
    var recordedRunTokens = 0
    var recordedRunUSD = 0.0

    func outcome(_ result: TurnResult) -> TurnOutcome {
      TurnOutcome(
        result: result,
        exchanges: exchanges,
        ingestedUntrusted: ingestedUntrusted,
        pendingApproval: pendingApproval
      )
    }

    for _ in 0..<max(1, budget.maxTurns) {
      // Per-round-trip preflight (§6.2): day totals at run start + everything this run recorded.
      let inputTokens = TokenEstimator.estimateInputTokens(wire)
      let estimate = inputTokens + budget.maxOutputTokens
      let estimatedCost = costResolver.resolve(
        model: model,
        usage: ChatUsage(
          promptTokens: inputTokens,
          completionTokens: budget.maxOutputTokens,
          totalTokens: estimate
        ),
        providerCost: nil
      ).costUSD
      // The run-accumulated per-run check (§15) lives here, not in BudgetGate (see preamble).
      if recordedRunUSD + estimatedCost > budget.perRunUSD {
        return outcome(.budgetStopped(cap: "per-run spend"))
      }
      if case .deny(let cap) = gate.preflight(
        todayTokens: todayTokens + recordedRunTokens,
        todayUSD: todayUSD + recordedRunUSD,
        estimatedTotalTokens: estimate,
        estimatedCostUSD: estimatedCost
      ) {
        return outcome(.budgetStopped(cap: cap))
      }

      guard Task.isCancelled == false else {
        return outcome(.degraded(.providerUnavailable, usage: nil))
      }
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else {
        return outcome(
          .degraded(
            .providerUnavailable,
            usage: estimatedDebit(context: wire, runId: runId, sessionId: sessionId)
          )
        )
      }

      let request = ChatRequest(
        model: model,
        messages: wire,
        maxOutputTokens: budget.maxOutputTokens,
        tools: definitions
      )

      let response: ChatResponse
      do {
        response = try await roundTrip(
          chatId: chatId,
          draftId: runId,
          request: request,
          deadlineSeconds: max(1, Int(remaining.components.seconds))
        )
      } catch is DeadlineExceeded {
        return outcome(
          .degraded(
            .providerUnavailable,
            usage: estimatedDebit(context: wire, runId: runId, sessionId: sessionId)
          )
        )
      } catch {
        // Streaming can partially deliver before a terminal error, so its terminal case still debits
        // an ESTIMATED row (`degradedForStreamingError`); the typing path debits nil for a terminal
        // (`degradedForCaughtError`). §15 estimated-debit rule; keeps
        // `terminalStreamFailureDegradesAndDebitsTheEstimate` green and both helpers live.
        let degradation =
          streamingEnabled
          ? degradedForStreamingError(error, context: wire, runId: runId, sessionId: sessionId)
          : degradedForCaughtError(error, context: wire, runId: runId, sessionId: sessionId)
        return outcome(degradation)
      }

      // No proposals → the terminal round-trip; its usage row rides the atomic commit (D6).
      guard response.toolCalls.isEmpty == false else {
        return outcome(
          classify(response: response, context: wire, runId: runId, sessionId: sessionId)
        )
      }

      // Intermediate round-trip: record its usage row IMMEDIATELY (D6). Spend that cannot be
      // recorded must stop being spent (§6 — review H2).
      let intermediate = usageRow(for: response, context: wire, runId: runId, sessionId: sessionId)
      do {
        try usageStore.recordUsage(intermediate)
      } catch StoreError.diskFull {
        throw StoreError.diskFull
      } catch {
        warn("mid-run usage write failed; halting provider calls: \(error)")
        return outcome(.degraded(.accountingFailed, usage: nil))
      }
      recordedRunTokens += intermediate.promptTokens + intermediate.completionTokens
      recordedRunUSD += intermediate.costUSD

      // Tool dispatch. The typing indicator is the progress signal between round-trips (§13).
      await typingIndicator.sendTyping(chatId: chatId)
      var observations: [ToolObservation] = []
      for call in response.toolCalls {
        proposedToolCalls += 1
        guard proposedToolCalls <= budget.maxToolCalls else {
          // Mid-batch cap (rev.1 L4): the under-cap prefix ran; the first over-cap proposal ends
          // the run. Executed observations in this batch are lost with the budget-stopped commit;
          // the taint flag still persists.
          return outcome(.budgetStopped(cap: "per-run tool-call"))
        }
        guard deadline > ContinuousClock.now else {
          return outcome(
            .degraded(
              .providerUnavailable,
              usage: estimatedDebit(context: wire, runId: runId, sessionId: sessionId)
            )
          )
        }

        let context = ToolDispatchContext(
          sessionTainted: sessionTainted,
          runIngestedUntrusted: ingestedUntrusted,
          assemblyPrivateData: buildResult.hasPrivateDataAccess,
          runPrivateData: runPrivateData,
          grant: grant,
          approvalAlreadyPending: pendingApproval != nil
        )
        guard let toolDispatcher else {
          observations.append(
            ToolObservation(
              callId: call.id,
              toolName: call.name,
              content: "No tools are available.",
              status: .error,
              ingestedUntrusted: false
            )
          )
          continue
        }
        let dispatched = await toolDispatcher.dispatch(call: call, context: context)
        try recordToolAudit(for: call, outcome: dispatched, runId: runId, sessionId: sessionId)

        observations.append(dispatched.observation)
        if dispatched.observation.ingestedUntrusted {
          ingestedUntrusted = true  // visible to the very next proposed call (§6.5)
        }
        if dispatched.observation.readPrivateData {
          runPrivateData = true  // rev.1 H1
        }
        if dispatched.consumedGrant {
          grant = nil  // single-use
        }
        if pendingApproval == nil, let request = dispatched.pendingApproval {
          pendingApproval = request  // first trip parks; later trips are observation-only
        }
      }

      // Grow the wire array with the exchange (D3); observations enter FENCED (§12).
      wire.append(
        ChatMessage(role: .assistant, content: response.content, toolCalls: response.toolCalls)
      )
      for observation in observations {
        wire.append(
          ChatMessage(
            role: .tool,
            content: LabeledContextFactory.make(
              label: observation.toolName,
              content: observation.content
            ).render(),
            toolCallId: observation.callId
          )
        )
      }
      exchanges.append(
        ToolExchange(
          assistantContent: response.content,
          toolCalls: response.toolCalls,
          observations: observations
        )
      )
    }

    return outcome(.budgetStopped(cap: "per-run turn"))
  }

  // MARK: - Load-bearing

  /// Marker error thrown by turn-runtime deadline children when the wall-clock window elapses; the
  /// `runTurn` shell maps it to the estimated-debit degradation path.
  struct DeadlineExceeded: Error {}

  /// One audit row per dispatch, written immediately, blocked calls included (FR-T1/§6). Audit is
  /// observability, not a gate: a non-diskFull failure logs and the run continues.
  private func recordToolAudit(
    for call: ToolCall,
    outcome dispatched: ToolDispatchOutcome,
    runId: Int64,
    sessionId: Int64
  ) throws {
    let event = AuditEvent(
      actor: .assistant,
      action: .toolCall,
      tool: call.name,
      argsRedacted: dispatched.argsRedacted,
      resultSize: dispatched.observation.content.utf8.count,
      decision: dispatched.observation.status.rawValue,
      runId: runId,
      sessionId: sessionId,
      ts: Date()
    )
    do {
      try auditLog.appendAudit(event)
    } catch StoreError.diskFull {
      throw StoreError.diskFull
    } catch {
      warn("tool audit write failed (continuing): \(error)")
    }
  }

  /// The reconciled usage row for an intermediate round-trip — same resolution as `classify`,
  /// without the terminal classification.
  private func usageRow(
    for response: ChatResponse,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> ProviderUsage {
    let resolvedUsage = usageResolver.resolve(response: response, context: context)
    let resolvedCost = costResolver.resolve(
      model: model,
      usage: resolvedUsage.usage,
      providerCost: response.costFromProvider
    )
    return ProviderUsage(
      runId: runId,
      sessionId: sessionId,
      model: model,
      usage: resolvedUsage,
      cost: resolvedCost,
      ts: Date()
    )
  }

  /// One provider round-trip inside the SHARED wall-clock window (§6.6): streaming when enabled,
  /// falling back to typing on a connect failure, else plain typing. `deadlineSeconds` is the
  /// REMAINING run budget, not a fresh 180 s. Throws the provider/deadline error; the loop maps it.
  private func roundTrip(
    chatId: Int64,
    draftId: Int64,
    request: ChatRequest,
    deadlineSeconds: Int
  ) async throws -> ChatResponse {
    guard streamingEnabled else {
      return try await runTypingTurn(
        chatId: chatId,
        request: request,
        deadlineSeconds: deadlineSeconds
      )
    }
    do {
      return try await runStreamingTurn(
        chatId: chatId,
        draftId: draftId,
        request: request,
        deadlineSeconds: deadlineSeconds
      )
    } catch ProviderError.connectFailed {
      return try await runTypingTurn(
        chatId: chatId,
        request: request,
        deadlineSeconds: deadlineSeconds
      )
    }
  }

  private func runStreamingTurn(
    chatId: Int64,
    draftId: Int64,
    request: ChatRequest,
    deadlineSeconds: Int
  ) async throws -> ChatResponse {
    let runtime = StreamingTurnRuntime(
      provider: provider,
      typingIndicator: typingIndicator,
      draftStreamer: draftStreamer,
      wallClockDeadlineSeconds: deadlineSeconds,
      sleep: sleep
    )
    return try await runtime.run(chatId: chatId, draftId: draftId, request: request)
  }

  private func runTypingTurn(
    chatId: Int64,
    request: ChatRequest,
    deadlineSeconds: Int
  ) async throws -> ChatResponse {
    let runtime = TypingTurnRuntime(
      provider: provider,
      typingIndicator: typingIndicator,
      wallClockDeadlineSeconds: deadlineSeconds,
      sleep: sleep
    )
    return try await runtime.run(chatId: chatId, request: request)
  }

  private func degradedForCaughtError(
    _ error: any Error,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> TurnResult {
    if let providerError = error as? ProviderError {
      switch providerError {
      case .connectFailed, .retryable:
        return .degraded(
          .providerUnavailable,
          usage: estimatedDebit(context: context, runId: runId, sessionId: sessionId)
        )
      case .terminal:
        return .degraded(.providerUnavailable, usage: nil)
      }
    }

    return .degraded(
      .providerUnavailable,
      usage: estimatedDebit(context: context, runId: runId, sessionId: sessionId)
    )
  }

  private func degradedForStreamingError(
    _ error: any Error,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> TurnResult {
    if let providerError = error as? ProviderError {
      switch providerError {
      case .connectFailed, .retryable, .terminal:
        return .degraded(
          .providerUnavailable,
          usage: estimatedDebit(context: context, runId: runId, sessionId: sessionId)
        )
      }
    }

    return .degraded(
      .providerUnavailable,
      usage: estimatedDebit(context: context, runId: runId, sessionId: sessionId)
    )
  }

  /// Maps a returned response to a result, debiting the reconciled usage (real, or estimated when
  /// the provider omits it): non-empty content → `.completed`; empty + `finishReason == "length"` →
  /// `.degraded(.outputTruncated)`; any other empty → `.degraded(.providerUnavailable)`. Cost is
  /// resolved via `costResolver` (provider cost wins) into the `ProviderUsage` row.
  private func classify(
    response: ChatResponse,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> TurnResult {
    let resolvedUsage = usageResolver.resolve(response: response, context: context)
    let resolvedCost = costResolver.resolve(
      model: model,
      usage: resolvedUsage.usage,
      providerCost: response.costFromProvider
    )
    let usage = ProviderUsage(
      runId: runId,
      sessionId: sessionId,
      model: model,
      usage: resolvedUsage,
      cost: resolvedCost,
      ts: Date()
    )

    if !response.content.isEmpty {
      return .completed(content: response.content, usage: usage)
    }

    if response.finishReason == "length" {
      return .degraded(.outputTruncated, usage: usage)
    }

    return .degraded(.providerUnavailable, usage: usage)
  }

  /// The pre-call estimated `ProviderUsage` debited when no real usage exists (deadline /
  /// exhausted retries): prompt from context, completion reserved at the output cap, cost via the
  /// best-effort tier. No provider cost exists for a call that never returned, so the resolver's
  /// heuristic tier carries USD (floored, never a silent $0 — D1/F19); the row is an estimate.
  private func estimatedDebit(
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> ProviderUsage {
    let resolvedUsage = usageResolver.estimate(
      context: context,
      maxOutputTokens: budget.maxOutputTokens
    )
    let resolvedCost = costResolver.resolve(
      model: model,
      usage: resolvedUsage.usage,
      providerCost: nil
    )
    return ProviderUsage(
      runId: runId,
      sessionId: sessionId,
      model: model,
      usage: resolvedUsage,
      cost: resolvedCost,
      ts: Date()
    )
  }
}
