/// The events that can move a run through its lifecycle. Distinct from `RunState` (the persisted
/// column) so the legality of a transition lives in one reducer rather than scattered across stores.
public enum RunEvent: Sendable, Equatable {
  case pickUp
  case complete
  /// Raised by a terminal/exhausted/timeout outcome *or* the boot sweep over an orphaned run.
  case fail
}

/// The run lifecycle reducer — the single source of truth for which `(state, event)` pairs are
/// legal. Canonical for Inc 1 (the stores still apply their transitions directly in SQL); the Inc 2
/// per-session lane routes its state changes through this so an illegal pair can't be persisted.
public enum RunFSM {
  /// Returns the next state for a legal transition, or `nil` for an illegal one. There is **no
  /// default arm that invents a state** — an unrecognized pair is a programmer error the caller must
  /// handle, not silently swallow.
  public static func reduce(state: RunState, on event: RunEvent) -> RunState? {
    switch (state, event) {
    case (.pending, .pickUp): .running
    case (.running, .complete): .done
    case (.running, .fail): .failed
    case (.pending, .fail): .failed
    default: nil
    }
  }
}
