/// Serializes journal publication, deletion and approved workspace writes without suspension.
public actor WorkspaceMutationGate {
  public init() {}

  public func perform<Value: Sendable>(_ body: @Sendable () throws -> Value) rethrows -> Value {
    try body()
  }
}
