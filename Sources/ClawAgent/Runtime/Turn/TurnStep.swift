import ClawCore

/// Why a turn stopped: the result the gateway commits and the payload-free cause the attempt
/// diagnostics record.
struct TurnExit {
  let result: TurnResult
  let failureCause: AttemptFailureCause?

  init(_ result: TurnResult, failureCause: AttemptFailureCause? = nil) {
    self.result = result
    self.failureCause = failureCause
  }

  /// The run was cancelled.
  static var interrupted: Self {
    Self(.degraded(.providerUnavailable, usage: nil), failureCause: .processInterruption)
  }

  /// The wall clock cannot admit another send, so no call is issued.
  static var deadline: Self {
    Self(.degraded(.providerUnavailable, usage: nil), failureCause: .deadline)
  }

  static func budgetStopped(cap: String, unpricedModel: String? = nil) -> Self {
    Self(.budgetStopped(cap: cap, unpricedModel: unpricedModel))
  }
}

/// A phase's verdict: carry on with its value, or stop the turn.
enum TurnStep<Value> {
  case proceed(Value)
  case exit(TurnExit)
}
