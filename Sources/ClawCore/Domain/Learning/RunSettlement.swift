import Foundation

/// The receipt a bound run's terminal transition leaves behind: which state won, why, when — and
/// whether the run's evidence is frozen.
///
/// Terminal and settled are two invariants, not one. `terminalAt` is written by the transaction
/// that wins the state, always. `settledAt` is written only where a later primary fact is
/// impossible; until it is set, usage, observations and live work may still land against the run.
public struct RunSettlement: Sendable, Equatable {
  public let runId: Int64
  public let winningState: RunState
  public let terminalCause: TerminalCause
  public let terminalAt: Date
  /// Nil while a primary fact is still owed — a cancelled or superseded run before its lane tail
  /// unwinds, or an approval crash window before its placeholder resolves.
  public let settledAt: Date?

  public init(
    runId: Int64,
    winningState: RunState,
    terminalCause: TerminalCause,
    terminalAt: Date,
    settledAt: Date?
  ) {
    self.runId = runId
    self.winningState = winningState
    self.terminalCause = terminalCause
    self.terminalAt = terminalAt
    self.settledAt = settledAt
  }
}

/// What a state transition records if it wins a terminal state. The two cases are the settlement
/// boundary made explicit at every call site: `settled` claims that no later primary fact is
/// possible, `deferred` hands that claim to whoever writes the fact still owed.
public enum TerminalDisposition: Sendable, Equatable {
  /// Every primary fact of the run is final in this same transaction, so its evidence may freeze.
  case settled(TerminalCause)
  /// The state is terminal but a fact is still owed — the in-flight round's usage, the placeholder
  /// observation, the lane's own unwinding. Settlement belongs to the writer of that fact.
  case deferred(TerminalCause)

  public var cause: TerminalCause {
    switch self {
    case .settled(let cause), .deferred(let cause): cause
    }
  }

  public var freezesEvidence: Bool {
    switch self {
    case .settled: true
    case .deferred: false
    }
  }
}

public extension CancelReason {
  /// The run event a command-driven termination raises. One switch, so `/stop` and `/new` cannot
  /// drift apart between the single-run and plural arms.
  var runEvent: RunEvent {
    switch self {
    case .cancelled: .cancel
    case .superseded: .supersede
    }
  }

  /// The typed terminal cause the same termination records. Read off the caller's own reason, not
  /// reconstructed from the state it produced: `CANCELLED` and `SUPERSEDED` are the two states
  /// `RunState` happens to distinguish, and every other cause it cannot.
  var terminalCause: TerminalCause {
    switch self {
    case .cancelled: .ownerCancelled
    case .superseded: .superseded
    }
  }
}
