import ClawCore
import ClawTestSupport

/// A roster whose bindings are named after their position, so a selection's identity is readable in
/// the expectation rather than inferred from the position it was asked for.
func makeRoster(hasFallback: Bool) -> ProviderRoster {
  func binding(_ reference: String) -> LLMRouteBinding {
    makeSingleRouteRoster(
      provider: SequenceProvider([]),
      wireModel: "\(reference)-wire",
      configuredReference: reference
    ).primary
  }

  return ProviderRoster(
    primary: binding("primary-model"),
    fallback: hasFallback ? binding("fallback-model") : nil
  )
}
