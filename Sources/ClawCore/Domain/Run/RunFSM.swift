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
  /// The gate demanded an approval mid-turn (suspend commit).
  case suspendForApproval
  /// A valid owner approval resolved the row; the waiter resumes the turn.
  case resumeApproved
  /// Reject/expiry resolved the row against the run.
  case resolveDenied
}

/// The run lifecycle reducer: the single source of truth for legal state changes.
public enum RunFSM {
  // The exhaustive no-default state×event switch is deliberate — a `default` arm would defeat the
  // compiler-enforced exhaustiveness — so `reduce`'s branch count (and thus its cyclomatic
  // complexity) is intrinsic to the design rather than incidental. The block form keeps the doc
  // comment attached to the declaration (a `disable:next` line between them would orphan it).
  // swiftlint:disable cyclomatic_complexity
  /// Returns the next state for a legal transition, or `nil` when the store must perform no write.
  ///
  /// Every state/event pair is explicit so adding a future state or event produces a compiler
  /// reminder to revisit the lifecycle rules.
  public static func reduce(state: RunState, on event: RunEvent) -> RunState? {
    switch (state, event) {
    case (.pending, .pickUp): .running
    case (.pending, .fail): .failed
    case (.pending, .cancel): .cancelled
    case (.pending, .supersede): .superseded
    case (.running, .complete): .done
    case (.running, .fail): .failed
    case (.running, .cancel): .cancelled
    case (.running, .supersede): .superseded
    case (.running, .suspendForApproval): .awaitingApproval
    case (.awaitingApproval, .resumeApproved): .running
    case (.awaitingApproval, .resolveDenied): .failed
    case (.awaitingApproval, .fail): .failed
    case (.awaitingApproval, .cancel): .cancelled
    case (.awaitingApproval, .supersede): .superseded
    case (.pending, .complete), (.pending, .suspendForApproval), (.pending, .resumeApproved),
      (.pending, .resolveDenied), (.running, .pickUp), (.running, .resumeApproved),
      (.running, .resolveDenied), (.awaitingApproval, .pickUp), (.awaitingApproval, .complete),
      (.awaitingApproval, .suspendForApproval):
      nil
    case (.done, _), (.failed, _), (.cancelled, _), (.superseded, _): nil
    }
  }
  // swiftlint:enable cyclomatic_complexity
}
