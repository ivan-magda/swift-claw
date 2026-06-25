/// Per-session FIFO lane. Actor isolation protects bookkeeping; the stored Task chain serializes
/// complete turn bodies across their suspension points.
public actor SessionActor {
  private var tail: Task<Void, Never>?
  private var inFlight: [Int64: Task<Void, Never>] = [:]

  public init() {}

  public func enqueue(runId: Int64, _ work: @Sendable @escaping () async -> Void) {
    let previous = tail
    let task = Task {
      _ = await previous?.value
      await work()
      self.finish(runId: runId)
    }
    tail = task
    inFlight[runId] = task
  }

  public func cancel(runId: Int64) {
    inFlight[runId]?.cancel()
  }

  public func cancelAll() {
    for task in inFlight.values {
      task.cancel()
    }
  }

  private func finish(runId: Int64) {
    inFlight[runId] = nil
    if inFlight.isEmpty {
      tail = nil
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
