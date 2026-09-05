import Foundation

package enum SubprocessTermination: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)
  case timedOut
  case cancelled
  case startFailed(String)
}

package struct CapturedCommandStream: Sendable, Equatable {
  package let bytes: Data
  package let totalBytes: Int
  package let truncated: Bool

  package init(bytes: Data, totalBytes: Int, truncated: Bool) {
    precondition(totalBytes >= bytes.count)
    self.bytes = bytes
    self.totalBytes = totalBytes
    self.truncated = truncated
  }
}

package struct SubprocessResult: Sendable, Equatable {
  package let termination: SubprocessTermination

  package let stdout: CapturedCommandStream
  package let stderr: CapturedCommandStream

  package let processIdentifier: Int32?

  package init(
    termination: SubprocessTermination,
    stdout: CapturedCommandStream,
    stderr: CapturedCommandStream,
    processIdentifier: Int32?
  ) {
    self.termination = termination
    self.stdout = stdout
    self.stderr = stderr
    self.processIdentifier = processIdentifier
  }
}
