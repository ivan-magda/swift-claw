import ClawCore
import Synchronization

/// What one logical inference call has exposed the owner to, reduced across every wire attempt it
/// makes:
///
///     notStarted → mayHaveStarted → completed | failed | cancelled
///             └─ proven clean head or definitely-not-sent failure → notStarted before wait/retry
///
final class ProviderAttemptExposure: Sendable {
  private struct State {
    var hasReachedTransport = false
    var observedCompletionTokens = 0
  }

  private let state = Mutex(State())

  init() {}

  var accounting: ProviderFailureAccounting {
    state.withLock { current in
      if current.hasReachedTransport {
        return .mayHaveStarted(observing: current.observedCompletionTokens)
      }
      return .notStarted
    }
  }

  /// Hand to `HTTPRequest.beginHandoff`. Throwing refuses the submission outright and nothing is
  /// sent; returning moves the attempt to `mayHaveStarted`, after which cancellation is
  /// conservative even if no response head ever arrives.
  ///
  /// - Throws: `CancellationError` when the caller was already cancelled. Raw, because before the
  ///   handoff the caller's own cancellation genuinely is the whole story.
  func beginHandoff() throws {
    try state.withLock { current in
      if Task.isCancelled {
        throw CancellationError()
      }
      current.hasReachedTransport = true
    }
  }

  /// Records that this attempt provably generated nothing, returning it to `notStarted` before the
  /// call reads a diagnostic body, refreshes a credential, sleeps, or starts another attempt.
  func noteProvenClean() {
    state.withLock { current in
      current.hasReachedTransport = false
    }
  }

  /// Raises the lower bound on what this call may already be billed for. Monotonic: a later chunk
  /// restating a smaller count must not walk the bound back down.
  func noteObserved(completionTokens: Int) {
    state.withLock { current in
      current.observedCompletionTokens = max(current.observedCompletionTokens, completionTokens)
    }
  }

  /// Pairs a natural failure's cause with this attempt's exposure, read in one lock operation so the
  /// accounting a caller reports is the one true reading rather than a second, possibly-changed one.
  /// The reducer stays the single source of that fact for every failure site the engine builds.
  func failure(_ cause: ProviderError) -> ProviderFailure {
    ProviderFailure(cause: cause, accounting: accounting)
  }

  /// The error a cancelled attempt owes its caller. `complete` has no session to report accounting
  /// through, so the distinction has to ride the error itself.
  func cancellationError() -> any Error {
    state.withLock { current -> any Error in
      if current.hasReachedTransport {
        return ProviderInferenceCancellation(observing: current.observedCompletionTokens)
      }
      return CancellationError()
    }
  }
}
