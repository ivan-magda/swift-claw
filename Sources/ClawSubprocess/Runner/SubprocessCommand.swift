import Foundation

package struct SubprocessCommand: Sendable, Equatable {
  package let arguments: [String]
  package let timeout: Duration
  package let captureLimit: Int
  package let teardownGracePeriod: Duration
  package let standardInput: Data
  package let environmentKeysToRemove: [String]

  package init(
    arguments: [String],
    timeout: Duration,
    captureLimit: Int,
    teardownGracePeriod: Duration,
    standardInput: Data = Data(),
    environmentKeysToRemove: [String] = []
  ) {
    precondition(captureLimit >= 0)
    self.arguments = arguments
    self.timeout = timeout
    self.captureLimit = captureLimit
    self.teardownGracePeriod = teardownGracePeriod
    self.standardInput = standardInput
    self.environmentKeysToRemove = environmentKeysToRemove
  }
}
