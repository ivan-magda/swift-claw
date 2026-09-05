import ClawSecrets
import Foundation

/// Converts the publisher's intentionally explicit uncertain-commit outcome into a durable write:
/// if the intended bytes landed, retry only the missing directory sync; otherwise fail closed.
enum EvaluationDurablePublication {
  static func publish(
    _ data: Data,
    to url: URL,
    publisher: SecureFilePublisher = SecureFilePublisher()
  ) throws {
    try publish(data, to: url, mode: .replace, publisher: publisher)
  }

  static func publishExclusive(
    _ data: Data,
    to url: URL,
    publisher: SecureFilePublisher = SecureFilePublisher()
  ) throws {
    try publish(data, to: url, mode: .exclusive, publisher: publisher)
  }

  private static func publish(
    _ data: Data,
    to url: URL,
    mode: SecureFilePublisher.PublicationMode,
    publisher: SecureFilePublisher
  ) throws {
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [url.deletingLastPathComponent(), url]
    )
    let outcome = try publisher.publish(data, to: url, mode: mode)
    guard publisher.proveDurable(outcome, at: url) else {
      throw EvaluationDurablePublicationError.commitUncertain(url.lastPathComponent)
    }
  }
}

enum EvaluationDurablePublicationError: Error, Sendable, Equatable {
  case commitUncertain(String)
}
