import ClawCore
import Synchronization

/// What one logical inference call has exposed the owner to, reduced across every wire attempt it
/// makes:
///
///     notStarted → mayHaveStarted → completed | failed | cancelled
///             └─ proven clean head or definitely-not-sent failure → notStarted before wait/retry
///
/// Locked rather than actor-isolated because the transport's handoff is a synchronous closure. That
/// closure is the attempt's linearization point — the last instant at which refusing still proves
/// nothing was written — so it cannot await anything, and the cancellation check and the transition
/// it guards have to happen in one lock operation or a cancellation could slip between them.
///
/// Exposure is re-established per attempt, never carried between two. Two disciplines reach that same
/// guarantee, and both are in use: the Chat Completions path reuses one instance across a call and
/// resets it through `noteProvenClean()` before each retry, while the Responses attempt engine mints
/// a fresh instance for every wire attempt so a clean reset cannot leak across the retry boundary
/// even in principle. Either way a retry re-enters through `beginHandoff()` from `notStarted`.
final class ProviderAttemptExposure: Sendable {
  private struct State {
    /// The whole phase. `notStarted` is a claim that nothing reached the model, so only a transport
    /// fact may set it — never a hopeful read of an error message.
    var hasReachedTransport = false
    var observedCompletionTokens = 0
  }

  private let state = Mutex(State())

  init() {}

  /// The attempt's exposure right now, for a caller building a failure or a terminal.
  var accounting: ProviderFailureAccounting {
    state.withLock { current in
      guard current.hasReachedTransport else { return .notStarted }
      return .mayHaveStarted(observing: current.observedCompletionTokens)
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
      // Read under the lock so a cancellation cannot land between the check and the transition and
      // leave the attempt claiming it never started.
      if Task.isCancelled {
        throw CancellationError()
      }
      current.hasReachedTransport = true
    }
  }

  /// Records that this attempt provably generated nothing, returning it to `notStarted` before the
  /// call reads a diagnostic body, refreshes a credential, sleeps, or starts another attempt.
  ///
  /// Only two facts may call this: a recognized non-success response head, which proves the server
  /// answered instead of inferring, and a transport failure typed `definitelyNotSent`. A
  /// cancellation racing the reset sees whichever took the lock first, so it reports
  /// `mayHaveStarted` unless this reset had already won.
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
      guard current.hasReachedTransport else { return CancellationError() }
      return ProviderInferenceCancellation(observing: current.observedCompletionTokens)
    }
  }
}
