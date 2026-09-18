import ClawAgent
import ClawCore

// MARK: - Learning Inference

extension LearningOperationRunner {
  /// Executes one authorized, tool-free learning call with at most one safe route switch. The
  /// returned route owns both successful and failed accounting; the original carrier is unchanged.
  func dispatchInference(
    messages: [ChatMessage],
    outputCap: Int,
    starting: RouteSelection
  ) async -> (result: ProviderCallResult, route: LLMRouteBinding) {
    var active = starting
    while true {
      let request = ChatRequest(
        model: active.binding.wireModel,
        messages: messages,
        maxOutputTokens: outputCap,
        tools: []
      )
      do {
        let response = try await active.binding.provider.complete(request: request)
        if active.position == .primary {
          _ = await cooldown?.recordSuccess()
        }
        return (.response(response), active.binding)
      } catch {
        guard let persistence = RouteSwitch.permits(error),
              let next = roster.failover(from: active.position)
        else {
          return (.failed(error), active.binding)
        }
        await cooldown?.arm(
          persistence: persistence,
          retryAfterSeconds: RouteSwitch.retryAfterSeconds(of: error)
        )
        active = next
      }
    }
  }

  func accountant(for route: LLMRouteBinding, outputCap: Int) -> ProviderUsageAccountant {
    ProviderUsageAccountant(
      configuredReference: route.configuredReference,
      costPolicy: route.costPolicy,
      reservationPolicy: route.reservationPolicy,
      costResolver: costResolver,
      outputCap: outputCap
    )
  }

  /// Closes a failed learning reservation with conservative spend or a provider-proven zero.
  func failedCallUsage(
    _ error: any Error,
    context: [ChatMessage],
    accountant: ProviderUsageAccountant
  ) -> LearningCallUsage {
    switch ProviderFailureAccounting.classify(error) {
    case .mayHaveStarted(let observedCompletionTokens):
      return LearningCallUsage(
        model: accountant.configuredReference,
        resolved: accountant.conservative(
          context: context,
          observedCompletionTokens: observedCompletionTokens
        )
      )
    case .notStarted:
      return LearningCallUsage(
        model: accountant.configuredReference,
        promptTokens: 0,
        completionTokens: 0,
        costUSD: 0,
        costSource: .providerReturned,
        isEstimated: false
      )
    }
  }
}
