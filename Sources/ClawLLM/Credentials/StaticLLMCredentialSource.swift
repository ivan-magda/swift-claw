import ClawCore
import Foundation

/// The credential source for a configured OpenAI-compatible endpoint: one immutable bearer, or none
/// at all. It has no state to rotate, so rejection and shutdown are genuinely nothing to do rather
/// than unimplemented — a refreshable source is a different type.
///
/// It never logs. The bearer reaches a redactor only through `redactionValues`, so no diagnostic in
/// this type can be the thing that prints it.
public struct StaticLLMCredentialSource: LLMCredentialSource {
  private let bearer: String?

  /// A bearer that is absent — or blank, which is how an unset secret arrives — authorizes with
  /// nothing, which is what keeps a local server with no key at all reachable. Blank is also refused
  /// as a redaction value: scrubbing whitespace would blank out every log line it appears in.
  public init(bearer: String?) {
    self.bearer = bearer.flatMap { value in
      value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
  }

  public func authorization() async throws -> LLMRequestAuthorization {
    guard let bearer else {
      return LLMRequestAuthorization(headers: [:], redactionValues: [], generation: .zero)
    }
    return LLMRequestAuthorization(
      headers: ["Authorization": "Bearer \(bearer)"],
      redactionValues: [bearer],
      generation: .zero
    )
  }

  public func reject(
    generation: LLMCredentialGeneration,
    disposition: LLMCredentialRejection
  ) async {}

  public func shutdown() async throws {}
}
