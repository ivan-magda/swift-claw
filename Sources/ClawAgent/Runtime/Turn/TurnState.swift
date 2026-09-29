import ClawCore
import Logging

/// The facts fixed for one turn segment: whom it serves, when its wall clock ends, and the logger
/// every line of the turn goes through.
struct TurnFrame {
  let scope: TurnScope
  let deadline: ContinuousClock.Instant
  let startedAt: ContinuousClock.Instant
  let log: Logger
}

/// Everything a turn changes as it runs, one owner per concern. A phase takes only the owners it
/// may change, so a tool batch cannot move the route and a send cannot touch the trust flags.
struct TurnState {
  var route: TurnRoute
  var attempts: AttemptRuntimeState
  var ledger: RunSpendLedger
  var trust: TurnTrust
  var transcript: TurnTranscript

  /// The outcome the gateway persists when the turn stops with `exit`.
  func outcome(for exit: TurnExit) -> TurnOutcome {
    TurnOutcome(
      result: exit.result,
      exchanges: transcript.exchanges,
      ingestedUntrusted: trust.ingestedUntrusted,
      hadPrivateData: trust.hadPrivateData,
      routeNotice: route.notice,
      attemptDiagnostics: attempts.diagnostics(failureCause: exit.failureCause)
    )
  }
}
