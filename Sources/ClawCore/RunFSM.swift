/// The events that can move a run through its lifecycle. Distinct from `RunState` (the persisted
/// column) so the legality of a transition lives in one reducer rather than scattered across stores.
public enum RunEvent: Sendable, Equatable {
  /// The session lane starts a durable PENDING run.
  case pickUp
  /// The assistant reply, usage, and outbox rows commit successfully.
  case complete
  /// Raised by a terminal/exhausted/timeout outcome *or* the boot sweep over an orphaned run.
  case fail
  /// `/stop` terminates a pending or running turn.
  case cancel
  /// `/new` terminates the running turn and any queued turns from the old conversation window.
  case supersede
}

/// The run lifecycle reducer: the single source of truth for legal state changes.
public enum RunFSM {
  /// Returns the next state for a legal transition, or `nil` when the store must perform no write.
  ///
  /// Every state/event pair is explicit so adding a future state or event produces a compiler
  /// reminder to revisit the lifecycle rules.
  public static func reduce(state: RunState, on event: RunEvent) -> RunState? {
    switch (state, event) {
    case (.pending, .pickUp):
      .running
    case (.pending, .fail):
      .failed
    case (.pending, .cancel):
      .cancelled
    case (.pending, .supersede):
      .superseded
    case (.running, .complete):
      .done
    case (.running, .fail):
      .failed
    case (.running, .cancel):
      .cancelled
    case (.running, .supersede):
      .superseded
    case (.pending, .complete), (.running, .pickUp):
      nil
    case (.done, _), (.failed, _), (.cancelled, _), (.superseded, _):
      nil
    }
  }
}
