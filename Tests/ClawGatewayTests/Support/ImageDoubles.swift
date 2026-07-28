import Foundation

@testable import ClawGateway

extension Result where Failure == ImageMessageFailure {
  /// Reads a materialization outcome as "refused for exactly this reason", so a test states the
  /// refusal it expects without unwrapping through a `switch` first.
  func isFailure(_ expected: ImageMessageFailure) -> Bool {
    guard case .failure(let actual) = self else {
      return false
    }
    return actual == expected
  }
}
