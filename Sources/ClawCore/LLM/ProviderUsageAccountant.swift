import Foundation

// MARK: - Shared usage accounting

/// The single accounting authority both a turn (`AgentRuntime`) and a command-scoped parse
/// (`ScheduleDraftParser`) mint their `provider_usage` rows through, so the two account identically
/// by construction rather than through parallel copies kept in sync by hand. It owns the route's
/// cost identity, its billing and reservation policies, and the two resolvers, and exposes the three
/// shapes a caller needs: the reconciled row a returned response yields, the conservative estimate a
/// call with no authoritative usage owes, and the pre-call estimate a budget gate reads.
public struct ProviderUsageAccountant: Sendable {
  /// The pre-call estimate a budget gate reads: reserved input for the input cap, the total for the
  /// token cap, and the USD figure for the spend cap.
  public struct PreflightEstimate: Sendable, Equatable {
    public let inputTokens: Int
    public let totalTokens: Int
    public let costUSD: Double

    public init(inputTokens: Int, totalTokens: Int, costUSD: Double) {
      self.inputTokens = inputTokens
      self.totalTokens = totalTokens
      self.costUSD = costUSD
    }
  }

  /// The accounting, cost-identity, and safe-diagnostic reference usage rows key on — held apart from
  /// the wire model so a subscription route's rows read `openai-chatgpt/<model>` and never collide
  /// with API-billed rows for the same wire model.
  public let configuredReference: String
  /// How the route is billed; a subscription route resolves a confirmed zero rather than a metered
  /// cost, and the USD gates are skipped for it upstream.
  public let costPolicy: LLMCostPolicy
  /// The token reservation replay state needs on top of ordinary text estimation, folded into an
  /// estimated prompt only so a state-carrying wire is never under-accounted.
  public let reservationPolicy: LLMInputReservationPolicy
  public let costResolver: CostResolver
  public let usageResolver: UsageResolver
  /// The route's output ceiling — a turn's `maxOutputTokens`, a parse's ceiling — reserved for
  /// completion in every estimate a call with no returned reply produces. Fixed per route, so it is
  /// owned here rather than threaded through each estimate call.
  public let outputCap: Int
  /// Where `ts` comes from, injected so a turn and a parse stamp their rows from one source rather
  /// than one calling `Date()` inline and the other an injected clock.
  private let now: @Sendable () -> Date

  public init(
    configuredReference: String,
    costPolicy: LLMCostPolicy,
    reservationPolicy: LLMInputReservationPolicy,
    costResolver: CostResolver,
    usageResolver: UsageResolver = UsageResolver(),
    outputCap: Int,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuredReference = configuredReference
    self.costPolicy = costPolicy
    self.reservationPolicy = reservationPolicy
    self.costResolver = costResolver
    self.usageResolver = usageResolver
    self.outputCap = outputCap
    self.now = now
  }

  /// The reconciled row for a response that carries authoritative usage — an intermediate round-trip,
  /// a terminal reply, or a reply that landed alongside a won deadline. Provider counts are truth and
  /// stay untouched; a missing count is estimated, and only there is the reservation folded in.
  /// Provider cost wins.
  public func reconciledRow(
    for response: ChatResponse,
    callID: ProviderCallID,
    context: [ChatMessage],
    tools: [ToolDefinition] = [],
    runId: Int64?,
    sessionId: Int64
  ) -> ProviderUsage {
    let resolved = reconciled(for: response, context: context, tools: tools)
    let resolvedUsage = resolved.usage
    let resolvedCost = resolved.cost
    return ProviderUsage(
      providerCallID: callID,
      runId: runId,
      sessionId: sessionId,
      model: configuredReference,
      usage: resolvedUsage,
      cost: resolvedCost,
      ts: now()
    )
  }

  /// The conservative row for a call with no authoritative usage — a deadline, an exhausted retry, an
  /// ambiguous failure, or a cancellation that may have generated tokens. Prompt is estimated from
  /// context plus the reservation; completion is the larger of the route's `outputCap` and any count
  /// production code observed, so a partial reply already seen is never under-charged. No provider
  /// cost exists for a call that never reconciled, so cost comes from the best-effort tier (floored,
  /// never a silent $0) or a confirmed zero under `includedPlan`. The row is an estimate.
  public func conservativeRow(
    callID: ProviderCallID,
    context: [ChatMessage],
    tools: [ToolDefinition] = [],
    observedCompletionTokens: Int,
    runId: Int64?,
    sessionId: Int64
  ) -> ProviderUsage {
    let resolved = conservative(
      context: context,
      tools: tools,
      observedCompletionTokens: observedCompletionTokens
    )
    let resolvedUsage = resolved.usage
    let resolvedCost = resolved.cost
    return ProviderUsage(
      providerCallID: callID,
      runId: runId,
      sessionId: sessionId,
      model: configuredReference,
      usage: resolvedUsage,
      cost: resolvedCost,
      ts: now()
    )
  }

  /// What a row is built from, without the row. A caller that records spend through a writer other
  /// than `provider_usage` — the learning result commit, which charges under the call id its own
  /// reservation already holds — needs these two provenances and nothing else, and inventing a row
  /// identity to reach them would put values on screen that no reader may trust.
  public struct Resolved: Sendable, Equatable {
    public let usage: ResolvedUsage
    public let cost: ResolvedCost

    public init(usage: ResolvedUsage, cost: ResolvedCost) {
      self.usage = usage
      self.cost = cost
    }
  }

  /// The reconciled provenances for a response that carries authoritative usage.
  public func reconciled(
    for response: ChatResponse,
    context: [ChatMessage],
    tools: [ToolDefinition] = []
  ) -> Resolved {
    let resolvedUsage = usageResolver.resolve(response: response, context: context, tools: tools)
      .addingReservation(reservationPolicy.additionalTokens(for: context))
    return Resolved(
      usage: resolvedUsage,
      cost: costResolver.resolve(
        model: configuredReference,
        usage: resolvedUsage.usage,
        providerCost: response.costFromProvider,
        policy: costPolicy
      )
    )
  }

  /// The conservative provenances for a call with no authoritative usage.
  public func conservative(
    context: [ChatMessage],
    tools: [ToolDefinition] = [],
    observedCompletionTokens: Int
  ) -> Resolved {
    let resolvedUsage =
      usageResolver
      .estimate(
        context: context,
        tools: tools,
        maxOutputTokens: max(outputCap, observedCompletionTokens)
      )
      .addingReservation(reservationPolicy.additionalTokens(for: context))
    return Resolved(
      usage: resolvedUsage,
      cost: costResolver.resolve(
        model: configuredReference,
        usage: resolvedUsage.usage,
        providerCost: nil,
        policy: costPolicy
      )
    )
  }

  /// The pre-call estimate a budget gate reads before a call is issued: reserved input, the total for
  /// the token cap, and the USD figure — resolved under the injected policy, so `includedPlan` yields
  /// a zero the dollar gate skips — for the spend cap.
  public func preflightEstimate(
    context: [ChatMessage],
    tools: [ToolDefinition] = []
  ) -> PreflightEstimate {
    let inputTokens = SaturatingArithmetic.sum(
      TokenEstimator.estimateInputTokens(context, tools: tools),
      reservationPolicy.additionalTokens(for: context)
    )
    let totalTokens = SaturatingArithmetic.sum(inputTokens, outputCap)
    let costUSD = costResolver.resolve(
      model: configuredReference,
      usage: ChatUsage(
        promptTokens: inputTokens,
        completionTokens: outputCap,
        totalTokens: totalTokens
      ),
      providerCost: nil,
      policy: costPolicy
    ).costUSD
    return PreflightEstimate(inputTokens: inputTokens, totalTokens: totalTokens, costUSD: costUSD)
  }
}
