import ClawCore

/// Records every announced call, so a test can assert one echo per command and read exactly what
/// the owner would have been told.
public actor RecordingInvocationEcho: ToolInvocationEchoing {
  public private(set) var echoes: [ToolInvocationEcho] = []
  private let succeeds: Bool

  public init(succeeds: Bool = true) {
    self.succeeds = succeeds
  }

  public func echo(_ invocation: ToolInvocationEcho) async -> Bool {
    echoes.append(invocation)
    return succeeds
  }

  /// How many announcements have landed. A tool double reads this from inside its own `execute` to
  /// make "the echo came first" an observable fact rather than an ordering assumption.
  public func landed() -> Int {
    echoes.count
  }
}
