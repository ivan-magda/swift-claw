import ClawCore
import Foundation
import Logging

/// Why a turn produced no usable answer. Maps to a plain-language degradation reply; the
/// stable `rawValue` is what the audit log records, so it survives case renames.
public enum DegradationKind: String, Sendable, Equatable {
  case providerUnavailable
  case outputTruncated
  case contextUnavailable
  case accountingFailed  // usage-write failure mid-run
}

/// The outcome of one orchestrated turn. `runTurn` never throws — every failure becomes one of
/// these so the gateway always has something to persist and send (never silence).
public enum TurnResult: Sendable, Equatable {
  /// A usable answer plus the reconciled, provider-truth usage to debit. `providerState` is the
  /// replay material the route produced with this answer, carried opaquely to the commit that
  /// persists the answer — nil from any route that mints none.
  case completed(content: String, usage: ProviderUsage, providerState: ProviderExchangeState?)
  /// No usable answer. `usage` is the real row when the call returned (truncation) or an
  /// estimated row when it didn't (deadline / exhausted retries); `nil` for terminal errors.
  case degraded(DegradationKind, usage: ProviderUsage?)
  /// The offline budget gate refused before any provider call; `cap` names the tripped limit.
  case budgetStopped(cap: String)
  /// The batch drained after an ask-tier proposal recorded its action; the gateway commits
  /// the durable suspend checkpoint. `usage` is the suspending round-trip's reconciled row — it was
  /// already recorded mid-loop, so the suspend commit must NOT re-debit it.
  case suspended(pending: PendingToolAction, usage: ProviderUsage)
}

/// The outcome of the bounded agentic loop: the terminal `TurnResult` plus everything the
/// gateway needs to persist and gate the next turn.
public struct TurnOutcome: Sendable {
  public let result: TurnResult
  /// Every round-trip that proposed tool calls, to persist.
  public let exchanges: [ToolExchange]
  /// Taint signal: any executed observation ingested untrusted content this run.
  public let ingestedUntrusted: Bool
  /// Private-data signal: the assembly flag (fitted USER/MEMORY sections) OR any executed
  /// observation that read private data this run — `assemblyPrivateData ∪ runPrivateData`. Every
  /// commit path persists it as `setPrivateData`.
  public let hadPrivateData: Bool

  public init(
    result: TurnResult,
    exchanges: [ToolExchange] = [],
    ingestedUntrusted: Bool = false,
    hadPrivateData: Bool = false
  ) {
    self.result = result
    self.exchanges = exchanges
    self.ingestedUntrusted = ingestedUntrusted
    self.hadPrivateData = hadPrivateData
  }
}

/// The pure orchestration of one blocking turn: preflight → typing + wall-clock deadline →
/// provider call → classify. No persistence or sending (the gateway owns that); all
/// collaborators are injected `ClawCore` protocols so tests drive it with mocks.
public struct AgentRuntime: Sendable {
  private let provider: any LLMProvider
  private let typingIndicator: any TypingIndicator
  private let draftStreamer: any RichDraftStreaming
  private let streamingEnabled: Bool

  // The cost/usage/reservation collaborators and identities are `internal`, not `private`, because
  // the accounting extension that reads them lives in `AgentRuntime+Accounting.swift`.
  let costResolver: CostResolver
  let usageResolver: UsageResolver
  let budget: RunBudget
  /// What crosses the wire in `ChatRequest.model`.
  private let wireModel: String
  /// The accounting, cost-identity, and safe-diagnostic reference. Kept apart from `wireModel` so a
  /// subscription route's usage rows key on `openai-chatgpt/<model>` and never collide with
  /// API-billed rows for the same wire model.
  let configuredReference: String
  /// How the route is billed. Injected — the loop never name-checks a model — so `includedPlan`
  /// records a confirmed zero and skips only the USD gates.
  let costPolicy: LLMCostPolicy
  /// The token reservation replay state needs on top of ordinary text estimation. Injected, so the
  /// loop reserves against persisted provider-state bytes it never decodes.
  let reservationPolicy: LLMInputReservationPolicy

  private let toolDispatcher: (any ToolDispatching)?

  private let usageStore: any UsageStore
  private let auditLog: any AuditLog
  /// Mints the identity each round-trip's usage row is recorded under. Injected so a test can pin
  /// the identities a run records rather than assert against a random UUID.
  private let providerCallIDGenerator: any ProviderCallIDGenerating
  /// Developer-facing diagnostics (swift-log). Distinct from `auditLog`, which is the durable
  /// business/security trail. Defaults to a no-op so tests stay silent unless they inject one.
  private let logger: Logger
  /// Injected so tests can script pacing (deadline, backoff) instead of waiting on wall-clock.
  private let clock: any Clock<Duration>

  public init(
    provider: any LLMProvider,
    typingIndicator: any TypingIndicator,
    draftStreamer: any RichDraftStreaming,
    streamingEnabled: Bool,
    costResolver: CostResolver,
    usageResolver: UsageResolver = UsageResolver(),
    budget: RunBudget,
    wireModel: String,
    configuredReference: String,
    costPolicy: LLMCostPolicy = .metered,
    reservationPolicy: LLMInputReservationPolicy = .textOnly,
    toolDispatcher: (any ToolDispatching)? = nil,
    usageStore: any UsageStore,
    auditLog: any AuditLog,
    providerCallIDGenerator: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator(),
    logger: Logger = Logger(label: "clawd.agent", factory: { _ in SwiftLogNoOpLogHandler() }),
    clock: any Clock<Duration>
  ) {
    self.provider = provider
    self.typingIndicator = typingIndicator
    self.draftStreamer = draftStreamer
    self.streamingEnabled = streamingEnabled

    self.costResolver = costResolver
    self.usageResolver = usageResolver
    self.budget = budget
    self.wireModel = wireModel
    self.configuredReference = configuredReference
    self.costPolicy = costPolicy
    self.reservationPolicy = reservationPolicy

    self.toolDispatcher = toolDispatcher

    self.usageStore = usageStore
    self.auditLog = auditLog
    self.providerCallIDGenerator = providerCallIDGenerator

    self.logger = logger

    self.clock = clock
  }

  // swiftlint:disable function_parameter_count function_body_length cyclomatic_complexity
  /// The bounded agentic loop: one context assembly, then up to `maxTurns` round-trips
  /// with per-round-trip budget preflight, gated tool dispatch, and immediate usage/audit writes.
  /// A DELIBERATE SOFTENING of "no persistence here": `usageStore`/`auditLog` are injected
  /// so mid-run rows survive a crash. Throws ONLY `StoreError.diskFull`; every
  /// other failure resolves in-band to a `TurnResult`.
  public func runTurn(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    buildResult: BuildResult,
    sessionTainted: Bool,
    sessionHasPrivateData: Bool,
    todayTokens: Int,
    todayUSD: Double,
    origin: RunOrigin = .interactive,
    proactiveTodayUSD: Double = 0,
    carryOver: ResumeUsage? = nil
  ) async throws -> TurnOutcome {
    let deadline = ContinuousClock.now + .seconds(budget.wallClockDeadlineSeconds)
    let definitions = toolDispatcher?.definitions ?? []
    let gate = BudgetGate(budget: budget, costPolicy: costPolicy)

    // Turn-scoped logger: every line below inherits run/session metadata, so one `grep run=<id>`
    // ties the round-trips, tool calls, and outcome of a single turn together.
    var turnLog = logger
    for (key, value) in Self.turnMetadata(runId: runId, sessionId: sessionId) {
      turnLog[metadataKey: key] = value
    }
    let turnStart = ContinuousClock.now
    turnLog.info(
      "turn started model=\(configuredReference) origin=\(origin) contextMessages=\(buildResult.messages.count) streaming=\(streamingEnabled) tools=\(definitions.count)"
    )

    var wire = buildResult.messages
    var exchanges: [ToolExchange] = []

    var ingestedUntrusted = false
    var runPrivateData = false

    var pendingSuspension: PendingToolAction?

    // Seeded from the carried-over usage (nil = a fresh run; a continuation carries the run's
    // persisted totals so the tool-call / token / USD caps keep counting across the suspension).
    var proposedToolCalls = carryOver?.toolCalls ?? 0
    var recordedRunTokens = carryOver?.tokens ?? 0
    var recordedRunUSD = carryOver?.costUSD ?? 0.0

    // Terminal choke-point for the RESULT paths: every `return outcome(...)` flows through here, so a
    // turn that produces a `TurnOutcome` emits exactly one finished line (see `logFinish`). The
    // `StoreError.diskFull` fast-path throws to the gateway instead, which logs that terminal.
    func outcome(_ result: TurnResult) -> TurnOutcome {
      Self.logFinish(result, on: turnLog, elapsed: ContinuousClock.now - turnStart)
      return TurnOutcome(
        result: result,
        exchanges: exchanges,
        ingestedUntrusted: ingestedUntrusted,
        hadPrivateData: buildResult.hasPrivateDataAccess || runPrivateData
      )
    }

    // The three wall-clock exits — exhausted before the send, exceeded during it, exceeded
    // mid-dispatch — all owe the estimate for the round they ended, over the wire that round was
    // (or would have been) sent. `wire` only grows once a round completes, so it reads the same at
    // each of them.
    func deadlineDegradation(_ callID: ProviderCallID) -> TurnResult {
      .degraded(
        .providerUnavailable,
        usage: conservativeDebit(
          callID: callID,
          context: wire,
          observedCompletionTokens: 0,
          runId: runId,
          sessionId: sessionId
        )
      )
    }

    // The wall-clock deadline is left per-segment by construction — it is recomputed at each
    // `runTurn` entry above; only the round count needs to account for rounds already consumed.
    let priorRounds = carryOver?.rounds ?? 0
    for roundTripIndex in 1...max(1, budget.maxTurns - priorRounds) {
      // One identity per logical round, minted before anything here can debit. Every row this
      // iteration can produce — the estimate a deadline forces, the reconciled row a response
      // yields — accounts for the same provider call, so whichever one lands is recorded under the
      // same key. It is deliberately not minted per wire attempt: the stream-to-buffered fallback
      // inside `roundTrip` retries the round, and a fresh identity there would let one round debit
      // the day twice.
      let callID = providerCallIDGenerator.next()

      // Per-round-trip preflight: day totals at run start + everything this run recorded. The
      // reservation for replay-state bytes rides on ordinary text estimation so a state-carrying
      // wire cannot slip past a token gate; the loop reserves against those bytes without decoding
      // them.
      let inputTokens =
        TokenEstimator.estimateInputTokens(wire) + reservationPolicy.additionalTokens(for: wire)
      // The loop is the one component that grows provider input (proposals + fenced
      // observations) and nothing re-fits the wire mid-run — without this check the
      // provider's context window is the de facto enforcement: an HTTP 400 classified terminal,
      // surfacing as an undiagnosable "provider unavailable". `budget.maxInputTokens` otherwise
      // binds only at assembly, which cannot see mid-run growth.
      if inputTokens > budget.maxInputTokens {
        return outcome(.budgetStopped(cap: BudgetGate.perRunInputTokenCap))
      }
      let estimate = inputTokens + budget.maxOutputTokens
      let estimatedCost = costResolver.resolve(
        model: configuredReference,
        usage: ChatUsage(
          promptTokens: inputTokens,
          completionTokens: budget.maxOutputTokens,
          totalTokens: estimate
        ),
        providerCost: nil,
        policy: costPolicy
      ).costUSD
      // The run-accumulated per-run check lives here, not in BudgetGate — and, like BudgetGate's
      // USD caps, it is a dollar gate a subscription call does not answer to. The token, input,
      // turn, and tool bounds above and below it stay live either way.
      if costPolicy == .metered, recordedRunUSD + estimatedCost > budget.perRunUSD {
        return outcome(.budgetStopped(cap: "per-run spend"))
      }
      if case .deny(let cap) = gate.preflight(
        todayTokens: todayTokens + recordedRunTokens,
        todayUSD: todayUSD + recordedRunUSD,
        estimatedTotalTokens: estimate,
        estimatedCostUSD: estimatedCost,
        origin: origin,
        proactiveTodayUSD: proactiveTodayUSD + recordedRunUSD
      ) {
        return outcome(.budgetStopped(cap: cap))
      }

      guard Task.isCancelled == false else {
        return outcome(.degraded(.providerUnavailable, usage: nil))
      }

      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else {
        turnLog.notice("round-trip \(roundTripIndex) wall-clock exhausted before send; degrading")
        return outcome(deadlineDegradation(callID))
      }

      turnLog.debug(
        "round-trip \(roundTripIndex) inputTokens~=\(inputTokens) estCostUSD=\(USD.precise(estimatedCost))"
      )
      let request = ChatRequest(
        model: wireModel,
        messages: wire,
        maxOutputTokens: budget.maxOutputTokens,
        tools: definitions,
        sessionId: SessionTraceID.format(sessionID: sessionId)
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
        turnLog.notice("round-trip \(roundTripIndex) exceeded the wall-clock deadline; degrading")
        return outcome(deadlineDegradation(callID))
      } catch {
        // One accounting decision for every natural failure and cancellation, keyed on the
        // vendor-neutral disposition the provider tagged the failure with — never on whether the
        // call went out through `stream` or `complete`. A proven no-start writes no row; anything
        // that may have generated tokens writes a conservative one.
        turnLog.warning("round-trip \(roundTripIndex) provider error (degrading): \(error)")
        return outcome(
          failureOutcome(
            error,
            callID: callID,
            context: wire,
            runId: runId,
            sessionId: sessionId
          )
        )
      }

      // No proposals → the terminal round-trip; its usage row rides the atomic commit.
      guard response.toolCalls.isEmpty == false else {
        return outcome(
          classify(
            response: response,
            callID: callID,
            context: wire,
            runId: runId,
            sessionId: sessionId
          )
        )
      }

      // Intermediate round-trip: record its usage row IMMEDIATELY. Spend that cannot be
      // recorded must stop being spent.
      let intermediate = usageRow(
        for: response,
        callID: callID,
        context: wire,
        runId: runId,
        sessionId: sessionId
      )
      do {
        try usageStore.recordUsage(intermediate)
      } catch StoreError.diskFull {
        throw StoreError.diskFull
      } catch {
        turnLog.warning("mid-run usage write failed; halting provider calls: \(error)")
        return outcome(.degraded(.accountingFailed, usage: nil))
      }
      recordedRunTokens += intermediate.promptTokens + intermediate.completionTokens
      recordedRunUSD += intermediate.costUSD

      // Tool dispatch. The typing indicator is the progress signal between round-trips.
      await typingIndicator.sendTyping(chatId: chatId)
      var observations: [ToolObservation] = []
      for call in response.toolCalls {
        proposedToolCalls += 1
        guard proposedToolCalls <= budget.maxToolCalls else {
          // Mid-batch cap: the under-cap prefix ran; the first over-cap proposal ends
          // the run. Executed observations in this batch are lost with the budget-stopped commit;
          // the taint flag still persists.
          return outcome(.budgetStopped(cap: "per-run tool-call"))
        }

        guard deadline > ContinuousClock.now else {
          return outcome(deadlineDegradation(callID))
        }

        let context = ToolDispatchContext(
          sessionTainted: sessionTainted,
          runIngestedUntrusted: ingestedUntrusted,
          assemblyPrivateData: buildResult.hasPrivateDataAccess,
          runPrivateData: runPrivateData,
          sessionHasPrivateData: sessionHasPrivateData,
          approvalAlreadyPending: pendingSuspension != nil
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

        turnLog.debug("tool \(call.name) invoked")
        let toolStart = ContinuousClock.now
        let dispatched = await toolDispatcher.dispatch(call: call, context: context)
        turnLog.debug(
          "tool \(call.name) done decision=\(dispatched.observation.status.rawValue) bytes=\(dispatched.observation.content.utf8.count) ms=\(Self.millis(ContinuousClock.now - toolStart))"
        )

        // Durable suspend: the FIRST ask-tier proposal records its action and parks the run.
        // The tool did NOT execute — its placeholder observation row and the approvalRequested
        // audit both ride the suspend commit, so skip both the toolCall audit and
        // the observation append here. Later gated calls in the batch see approvalAlreadyPending
        // and return a blocked observation instead (requiresApproval nil), which appends
        // normally below.
        if pendingSuspension == nil, let recordedAction = dispatched.requiresApproval {
          pendingSuspension = PendingToolAction(toolCallId: call.id, recorded: recordedAction)
          continue
        }

        try recordToolAudit(for: call, outcome: dispatched, runId: runId, sessionId: sessionId)

        observations.append(dispatched.observation)
        if dispatched.observation.ingestedUntrusted {
          ingestedUntrusted = true  // visible to the very next proposed call
        }
        if dispatched.observation.readPrivateData {
          runPrivateData = true
        }
      }

      // Grow the wire array with the exchange; observations enter FENCED. The anchor carries the
      // state this round produced, opaquely: only the route that minted it may read it, and this
      // loop stays provider-agnostic by never looking.
      wire.append(
        ChatMessage(
          role: .assistant,
          content: response.content,
          toolCalls: response.toolCalls,
          providerState: response.providerState
        )
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
          observations: observations,
          providerState: response.providerState
        )
      )

      // The batch has drained. If an ask-tier proposal parked, return the suspend result now.
      // `intermediate` is THIS round-trip's already-recorded usage (recorded above via
      // `usageStore.recordUsage`); the exchange above carries the assistant anchor + completed
      // observations, and the parked call's placeholder is reserved at the suspend commit.
      if let pending = pendingSuspension {
        return outcome(.suspended(pending: pending, usage: intermediate))
      }
    }

    return outcome(.budgetStopped(cap: "per-run turn"))
  }
  // swiftlint:enable function_parameter_count function_body_length cyclomatic_complexity
}

// MARK: - Deadline Signal

extension AgentRuntime {
  /// Marker error thrown by turn-runtime deadline children when the wall-clock window elapses; the
  /// `runTurn` shell maps it to the estimated-debit degradation path.
  struct DeadlineExceeded: Error {}
}

// MARK: - Turn Diagnostics

private extension AgentRuntime {
  /// The correlation fields stamped on every developer log line for one turn, so a single
  /// `grep run=<id>` ties the turn's round-trips, tool calls, and outcome together.
  static func turnMetadata(runId: Int64, sessionId: Int64) -> Logger.Metadata {
    ["run": "\(runId)", "session": "\(sessionId)"]
  }

  /// Emits the one finished line for a turn; its level reflects severity — completed → info,
  /// budget-stopped → notice (an expected guard), degraded → warning (something went wrong). Only
  /// safe fields (counts, tokens, cost, elapsed) are logged, never the reply text.
  static func logFinish(_ result: TurnResult, on log: Logger, elapsed: Duration) {
    let elapsedMillis = millis(elapsed)
    switch result {
    case .completed(let content, let usage, _):
      log.info(
        "turn finished completed chars=\(content.count) tokens=\(usage.promptTokens + usage.completionTokens) usd=\(USD.precise(usage.costUSD)) ms=\(elapsedMillis)"
      )
    case .degraded(let kind, let usage):
      let tokens = usage.map { "\($0.promptTokens + $0.completionTokens)" } ?? "n/a"
      log.warning(
        "turn finished degraded kind=\(kind.rawValue) tokens=\(tokens) ms=\(elapsedMillis)"
      )
    case .budgetStopped(let cap):
      log.notice("turn finished budget-stopped cap=\(cap) ms=\(elapsedMillis)")
    case .suspended(let pending, let usage):
      log.info(
        "turn finished suspended tool=\(pending.recorded.tool) tokens=\(usage.promptTokens + usage.completionTokens) ms=\(elapsedMillis)"
      )
    }
  }

  /// Whole milliseconds of a `Duration`, for compact latency fields in developer logs.
  static func millis(_ duration: Duration) -> Int64 {
    let parts = duration.components
    return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
  }
}

// MARK: - Round-Trip Recording

private extension AgentRuntime {
  /// One audit row per dispatch, written immediately, blocked calls included. Audit is
  /// observability, not a gate: a non-diskFull failure logs and the run continues.
  func recordToolAudit(
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
      logger.warning(
        "tool audit write failed (continuing): \(error)",
        metadata: Self.turnMetadata(runId: runId, sessionId: sessionId)
      )
    }
  }

  /// The reconciled usage row for an intermediate round-trip — same resolution as `classify`,
  /// without the terminal classification.
  func usageRow(
    for response: ChatResponse,
    callID: ProviderCallID,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> ProviderUsage {
    let resolvedUsage = reservedUsage(for: response, context: context)
    let resolvedCost = costResolver.resolve(
      model: configuredReference,
      usage: resolvedUsage.usage,
      providerCost: response.costFromProvider,
      policy: costPolicy
    )

    return ProviderUsage(
      providerCallID: callID,
      runId: runId,
      sessionId: sessionId,
      model: configuredReference,
      usage: resolvedUsage,
      cost: resolvedCost,
      ts: Date()
    )
  }
}

// MARK: - Provider Round Trip

private extension AgentRuntime {
  /// One provider round-trip inside the SHARED wall-clock window: streaming when enabled,
  /// falling back to typing on a connect failure or a clean pre-stream rejection, else plain typing.
  /// `deadlineSeconds` is the REMAINING run budget, not a fresh 180 s. Throws the provider/deadline
  /// error; the loop maps it.
  func roundTrip(
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
    } catch ProviderError.connectFailed, ProviderError.rejected {
      // connectFailed: nothing was transmitted. rejected: the head carried an error status before
      // any SSE bytes, so the server generated nothing — the no-double-issue rationale does
      // not apply. Either way one blocking attempt is safe; `complete` brings its own retry
      // budget, backoff, and Retry-After handling, all inside the remaining wall-clock window.
      return try await runTypingTurn(
        chatId: chatId,
        request: request,
        deadlineSeconds: deadlineSeconds
      )
    }
  }

  func runStreamingTurn(
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
      clock: clock
    )
    return try await runtime.run(chatId: chatId, draftId: draftId, request: request)
  }

  func runTypingTurn(
    chatId: Int64,
    request: ChatRequest,
    deadlineSeconds: Int
  ) async throws -> ChatResponse {
    let runtime = TypingTurnRuntime(
      provider: provider,
      typingIndicator: typingIndicator,
      wallClockDeadlineSeconds: deadlineSeconds,
      clock: clock
    )
    return try await runtime.run(chatId: chatId, request: request)
  }
}
