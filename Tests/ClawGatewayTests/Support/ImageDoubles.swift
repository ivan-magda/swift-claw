import Foundation

@testable import ClawGateway

/// Canned image bodies for tests that need "a real image" and do not care which one.
enum ImageFixtures {
  /// The shortest body `ImageMediaType.sniff` accepts as a JPEG.
  static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
}

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
