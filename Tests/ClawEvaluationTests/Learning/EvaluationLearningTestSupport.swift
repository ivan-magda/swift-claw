@testable import ClawEvaluation

func routeObject(_ route: EvaluationLearningRouteBinding) -> [String: Any] {
  [
    "max_output_graphemes": route.maxOutputGraphemes,
    "max_output_tokens": route.maxOutputTokens,
    "max_output_utf8_bytes": route.maxOutputUTF8Bytes,
    "provider_reference": route.providerReference,
    "retry_budget": route.retryBudget,
    "wire_model": route.wireModel,
  ]
}
