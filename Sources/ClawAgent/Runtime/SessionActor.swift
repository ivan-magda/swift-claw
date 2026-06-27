/// Per-session FIFO lane. Actor isolation protects bookkeeping; the stored Task chain serializes
/// complete turn bodies across their suspension points.
public actor SessionActor {
  private var lastEnqueuedTask: Task<Void, Never>?
  private var inFlightTasks: [Int64: Task<Void, Never>] = [:]

  public init() {}

  public func enqueue(runId: Int64, _ work: @Sendable @escaping () async -> Void) {
    let previous = lastEnqueuedTask
    let task = Task {
      _ = await previous?.value
      await work()
      self.finish(runId: runId)
    }
    lastEnqueuedTask = task
    inFlightTasks[runId] = task
  }

  public func cancel(runId: Int64) {
    inFlightTasks[runId]?.cancel()
  }

  public func cancelAll() {
    for task in inFlightTasks.values {
      task.cancel()
    }
  }

  private func finish(runId: Int64) {
    inFlightTasks[runId] = nil
    if inFlightTasks.isEmpty {
      lastEnqueuedTask = nil
    }
  }
}

public actor SessionLaneRegistry {
  private var actors: [Int64: SessionActor] = [:]

  public init() {}

  public func actor(for sessionId: Int64) -> SessionActor {
    if let existing = actors[sessionId] {
      return existing
    }

    let created = SessionActor()
    actors[sessionId] = created
    return created
  }

  public var count: Int {
    actors.count
  }
}
