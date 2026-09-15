/// Marks when an async operation has finished, so a test can assert it is still in flight.
///
/// Pair it with a `Task.yield()` rather than a wall-clock window: the question it answers is "has
/// this returned yet", and the answer must not depend on how loaded the machine is.
public actor CompletionFlag {
  public private(set) var done = false

  public init() {}

  public func markDone() {
    done = true
  }
}
