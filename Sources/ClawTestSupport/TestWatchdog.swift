/// Bounds a missing completion signal, then cancels and joins the operation on failure.
public func withTestWatchdog<Result: Sendable>(
  onTimeout: @Sendable () -> Void,
  _ operation: @Sendable @escaping () async -> Result
) async -> Result {
  let completed = AsyncGate()
  let task = Task {
    defer { completed.open() }
    return await operation()
  }
  return await withTaskCancellationHandler {
    if !(await completed.waitUntilOpen()) {
      task.cancel()
      if !Task.isCancelled {
        onTimeout()
      }
    }
    return await task.value
  } onCancel: {
    task.cancel()
  }
}
