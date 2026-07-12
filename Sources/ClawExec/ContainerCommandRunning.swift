import Foundation

public struct ContainerCommand: Sendable, Equatable {
  public let arguments: [String]
  public let timeout: Duration
  public let captureLimit: Int
  public let teardownGracePeriod: Duration

  public init(
    arguments: [String],
    timeout: Duration,
    captureLimit: Int,
    teardownGracePeriod: Duration
  ) {
    precondition(captureLimit >= 0)
    self.arguments = arguments
    self.timeout = timeout
    self.captureLimit = captureLimit
    self.teardownGracePeriod = teardownGracePeriod
  }
}

public enum ContainerCommandTermination: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)
  case timedOut
  case cancelled
  case startFailed(String)
}

public struct CapturedCommandStream: Sendable, Equatable {
  public let bytes: Data
  public let totalBytes: Int
  public let truncated: Bool

  public init(bytes: Data, totalBytes: Int, truncated: Bool) {
    precondition(totalBytes >= bytes.count)
    self.bytes = bytes
    self.totalBytes = totalBytes
    self.truncated = truncated
  }
}

public struct ContainerCommandResult: Sendable, Equatable {
  public let termination: ContainerCommandTermination
  public let stdout: CapturedCommandStream
  public let stderr: CapturedCommandStream
  public let processIdentifier: Int32?
  public let wallClock: Duration

  public init(
    termination: ContainerCommandTermination,
    stdout: CapturedCommandStream,
    stderr: CapturedCommandStream,
    processIdentifier: Int32?,
    wallClock: Duration
  ) {
    self.termination = termination
    self.stdout = stdout
    self.stderr = stderr
    self.processIdentifier = processIdentifier
    self.wallClock = wallClock
  }
}

public protocol ContainerCommandRunning: Sendable {
  func run(_ command: ContainerCommand) async -> ContainerCommandResult
}
