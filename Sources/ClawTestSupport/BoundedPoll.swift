/// The shared ceiling for bounded test polls. A successful poll returns as soon as its condition
/// holds; the ceiling only limits a failing path on an oversubscribed CI runner.
public let boundedTestPollCeiling: Duration = .seconds(30)

/// Re-runs `probe` until it yields a value or the bounded wall-clock allowance expires.
public func pollUntil<Value>(
  timeout: Duration = boundedTestPollCeiling,
  interval: Duration = .milliseconds(10),
  _ probe: () throws -> Value?
) async rethrows -> Value? {
  let deadline = ContinuousClock.now + timeout

  while true {
    if let value = try probe() {
      return value
    }

    if ContinuousClock.now >= deadline {
      return nil
    }

    try? await Task.sleep(for: interval)
  }
}

/// Truth-valued convenience for `pollUntil`, keeping optional unwrapping out of assertions.
public func pollUntilTrue(
  timeout: Duration = boundedTestPollCeiling,
  interval: Duration = .milliseconds(10),
  _ probe: () throws -> Bool
) async rethrows -> Bool {
  try await pollUntil(
    timeout: timeout,
    interval: interval
  ) {
    try probe() ? true : nil
  } ?? false
}
