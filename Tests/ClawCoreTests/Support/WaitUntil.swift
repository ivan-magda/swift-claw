import Testing

/// A ceiling on `waitUntil`, generous enough that only a never-satisfied condition reaches it: the
/// awaited task needs no wall-clock time, only a turn on the executor.
private let yieldCeiling = 100_000

/// Yields until `condition` holds. This is not a wall-clock wait: the task being waited on only
/// needs to be scheduled to reach its suspension point, so the loop ends on the first turn after it
/// parks. Exhausting the ceiling names the condition that never came instead of letting the suite's
/// time limit kill an anonymous run.
func waitUntil(
  _ description: String,
  sourceLocation: SourceLocation = #_sourceLocation,
  _ predicate: @Sendable () -> Bool
) async {
  for _ in 0..<yieldCeiling {
    if predicate() { return }
    await Task.yield()
  }
  Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}
