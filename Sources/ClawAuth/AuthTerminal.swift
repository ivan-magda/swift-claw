import Foundation

// MARK: - Presentation

/// Where a line belongs. The distinction is not decoration: an owner piping `auth status` into a
/// script must get the report on stdout and the complaints somewhere else, and a command that mixed
/// them would make its own output unparseable.
public enum AuthPresentationDestination: Sendable, Equatable {
  case standardOutput
  case standardError
}

/// One line the workflow wants an owner to see, already safe to print. Everything remote has been
/// sanitized and redacted before it reaches a `text`, so a renderer never has to decide.
public struct AuthPresentationEvent: Sendable, Equatable {
  public let text: String
  public let destination: AuthPresentationDestination

  public init(text: String, destination: AuthPresentationDestination) {
    self.text = text
    self.destination = destination
  }

  public static func output(_ text: String) -> AuthPresentationEvent {
    AuthPresentationEvent(text: text, destination: .standardOutput)
  }

  public static func error(_ text: String) -> AuthPresentationEvent {
    AuthPresentationEvent(text: text, destination: .standardError)
  }
}

// MARK: - Terminal

/// The owner's end of a login: somewhere to write, somewhere to read, and whether anyone is actually
/// there. `isInteractive` is injected rather than sniffed, so a test can drive both the prompted and
/// the unattended path without owning a pty — and so the deterministic default a piped run takes is
/// provably the one a terminal would have offered.
///
/// Login writes through this as it goes rather than returning a transcript to print at the end: an
/// owner cannot approve a code they have not been shown, and a device code printed after the poll
/// loop finished would be a code for a login that already timed out.
public protocol AuthTerminal: Sendable {
  var isInteractive: Bool { get }

  /// The owner's next line, or nil at end of input. Nil is an answer — it means "take the default" —
  /// rather than a failure.
  func readLine() async throws -> String?

  func write(_ event: AuthPresentationEvent) async
}
