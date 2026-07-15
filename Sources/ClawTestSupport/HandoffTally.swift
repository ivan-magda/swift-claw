import ClawCore
import Synchronization

/// Runs a request's handoff on a double's behalf and counts the runs.
///
/// The count is of invocations actually made. Deriving it from the request instead — it carried a
/// handoff, so call it one — can only ever report back the assumption the double started with, and a
/// double that cannot observe a second call is no guard on an exactly-once property.
public final class HandoffTally: Sendable {
  private let count = Mutex(0)

  public init() {}

  /// How many times `run` has invoked a handoff, refusals included: a handoff that threw still ran.
  public var value: Int {
    count.withLock { current in
      current
    }
  }

  /// Invokes `handoff` when the request carried one, counting the invocation.
  ///
  /// - Throws: `handoff`'s own error, unchanged — a refusal belongs to the caller that authored it.
  public func run(_ handoff: (@Sendable () throws -> Void)?) throws {
    guard let handoff else { return }
    count.withLock { current in
      current += 1
    }
    try handoff()
  }
}
