package protocol SubprocessRunning: Sendable {
  func run(_ command: SubprocessCommand) async -> SubprocessResult
}
