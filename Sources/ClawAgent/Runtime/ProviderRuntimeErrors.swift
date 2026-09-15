import ClawCore

/// Thrown by a turn runtime when a real response landed alongside a won deadline. The owner still
/// sees a timeout, but the response rides the throw so the runtime books its usage through the
/// authoritative completed-call route — real counts, provider cost — rather than the estimate a bare
/// timeout would force. It is the error form of `.timedOut(.completed)`, kept distinct from
/// `ProviderInferenceCancellation` precisely because it carries the response, not just a token bound.
public struct RacedDeadlineSuccess: Error, Sendable {
  public let response: ChatResponse

  public init(response: ChatResponse) {
    self.response = response
  }
}

/// Raised when a streamed reply's accumulated content overruns the local byte cap. Owned here so the
/// coordinator's drain and the streaming runtime read one type rather than two copies.
struct AccumulatedStreamContentTooLarge: Error {}

/// The wall-clock deadline won before the provider could start inference. Kept distinct from task
/// cancellation so attempt diagnostics can record a deadline while accounting still books no row.
struct ProviderNoStartDeadline: Error, Sendable {}
