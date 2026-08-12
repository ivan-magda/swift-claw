import ClawCore
import Foundation

// MARK: - Results

/// How a command ended, in the vocabulary the workflow reasons in rather than in process codes. The
/// distinction that earns each case is what an owner must do next, and what a supervisor should make
/// of it: a cancelled login and a refused grant are both "no credential", but only one of them is
/// anybody's fault.
public enum AuthCommandExit: Sendable, Equatable {
  case success
  /// The owner walked away. Nothing was changed, and nothing is wrong.
  case cancelled
  /// The secret backend could not be brought up or opened. Non-retryable, and the daemon's own
  /// startup already means something specific by it.
  case secretLoadFailure
  case commandFailure

  /// The code the process exits with. `cancelled` is 130 because that is what a shell reads as
  /// "interrupted", and the secret-load case reuses the daemon's existing code rather than minting a
  /// second number for the same condition — a supervisor already knows to back off on that one.
  public var processExitCode: Int32 {
    switch self {
    case .success:
      return 0
    case .cancelled:
      return 130
    case .secretLoadFailure:
      return ClawExitCode.secretLoadFailed.rawValue
    case .commandFailure:
      return 1
    }
  }
}

public struct AuthCommandResult: Sendable, Equatable {
  public let exit: AuthCommandExit

  /// Everything the command still wants an owner to see, in order, and none of it shown yet — so a
  /// renderer prints all of it, for every command, without asking which one it is holding.
  ///
  /// The invariant is what makes that safe, and it is why login returns nothing here. Login must
  /// stream as it goes, because a device code an owner has not been shown is a code for a window
  /// that will close before they see it; having already presented every line, it has none left to
  /// hand over. Status and logout say nothing until they are done, so theirs is the whole report.
  public let events: [AuthPresentationEvent]

  public init(exit: AuthCommandExit, events: [AuthPresentationEvent]) {
    self.exit = exit
    self.events = events
  }
}

// MARK: - Mapper

/// Turns a failure into the ending an owner sees and a shell reads.
///
/// It exists so the table is in one place and can be read as a table. Scattering these decisions
/// through the workflow would make "does a broken envelope really exit 11?" a question answered by
/// tracing control flow.
public enum AuthCommandResultMapper {
  public static let cancelled = AuthCommandResult(
    exit: .cancelled,
    events: [.error("Cancelled. The stored credential is unchanged.")]
  )

  public static func result(for failure: AuthMutationLockFailure) -> AuthCommandResult {
    switch failure {
    case .held:
      return AuthCommandResult(
        exit: .commandFailure,
        events: [
          .error(
            """
            clawd is running for this state root. Stop the daemon before changing the stored \
            credential, then run this again.
            """
          )
        ]
      )
    case .unavailable(let detail):
      return AuthCommandResult(
        exit: .commandFailure,
        events: [.error("The state root's lock could not be opened: \(safe(detail))")]
      )
    }
  }

  /// Every runtime-secret failure, named or not, is a secret-load failure. Falling through to an
  /// ordinary command failure on an error no case happens to name would be the one mistake that
  /// matters here: it would tell a supervisor to try again on a condition that will never fix
  /// itself.
  public static func runtimeSecretResult(for error: any Error) -> AuthCommandResult {
    let named = error as? SecretStoreError
    let cause =
      if let named {
        describe(named)
      } else {
        "the runtime secrets could not be prepared"
      }

    return AuthCommandResult(
      exit: .secretLoadFailure,
      events: [
        .error("Login stopped before touching your credentials: \(cause)."),
        .error(repair(for: named)),
      ]
    )
  }

  /// Worded for a read and a write alike: login saves through this seam, status and logout read
  /// through it, and a lead that named one of those would be wrong for the other two.
  public static func result(for error: LLMCredentialStoreError) -> AuthCommandResult {
    AuthCommandResult(
      exit: .secretLoadFailure,
      events: [.error("The stored credential could not be accessed: \(describe(error)).")]
    )
  }

  public static func credentialStoreResult(for error: any Error) -> AuthCommandResult {
    guard let named = error as? LLMCredentialStoreError else {
      return unexpected()
    }
    return result(for: named)
  }

  public static func result(for failure: ChatGPTOAuthFailure) -> AuthCommandResult {
    AuthCommandResult(
      exit: .commandFailure,
      events: [.error("Login failed: \(describe(failure)).")]
    )
  }

  /// A failure no seam named. It is an ordinary command failure, and it says nothing about the error
  /// it came from: an unrecognized value is exactly the one whose description nobody has checked for
  /// a token. Every command shares it, so it names none of them.
  public static func unexpected() -> AuthCommandResult {
    AuthCommandResult(
      exit: .commandFailure,
      events: [.error("The command failed for an unexpected reason.")]
    )
  }
}

// MARK: - Wording

private extension AuthCommandResultMapper {
  /// What to actually do about it, which is not the same sentence for every cause. A seal is the
  /// repair for an encrypted backend that is broken or half-written — but not for a missing bot
  /// token, because there is nothing to seal until the owner supplies one, and telling them to seal
  /// first would send them back to this same failure. The token is named by its role rather than by
  /// its variable: which environment the daemon reads belongs to the concrete store, not here.
  static func repair(for error: SecretStoreError?) -> String {
    if error == .missingTelegramToken {
      return """
        Put the Telegram bot token in the daemon's environment first — there is nothing to seal \
        without it — then run `clawd secrets seal` and log in again.
        """
    }
    return """
      Both \(SecretFile.key) and \(SecretFile.envelope) must be present and readable. \
      Run `clawd secrets seal` to repair the encrypted secret backend, then log in again.
      """
  }

  static func describe(_ error: SecretStoreError) -> String {
    switch error {
    case .missingTelegramToken:
      return "no Telegram bot token is configured to seal"
    case .keyFileInsecure(let detail):
      return safe(detail)
    case .malformedEnvelope:
      return "\(SecretFile.envelope) is not an envelope this build can read"
    case .decryptionFailed:
      return "\(SecretFile.envelope) did not decrypt under \(SecretFile.key)"
    case .unreadable(let name):
      return "\(safe(name)) could not be read"
    case .publicationFailed(let detail):
      return safe(detail)
    }
  }

  /// The credential envelope is named by its role rather than its filename: the file's path belongs
  /// to the concrete store, which this module does not — and must not — depend on.
  static func describe(_ error: LLMCredentialStoreError) -> String {
    switch error {
    case .missingRuntimeKey:
      return "\(SecretFile.key) is missing"
    case .insecureStorage:
      return "its envelope is not owner-only, or is not a regular file"
    case .malformedStorage:
      return "its envelope is not one this build can open"
    case .unsupportedVersion:
      return "its envelope was written by a newer build"
    case .oversizedStorage:
      return "its envelope is larger than this build will read"
    case .publicationFailed:
      return "its envelope could not be written"
    case .commitUncertain:
      return "its envelope was written but not proven durable"
    }
  }

  static func describe(_ failure: ChatGPTOAuthFailure) -> String {
    switch failure {
    case .deadlineExceeded:
      return "the approval window closed before the device was approved"
    case .throttled(let retryAfter):
      guard let retryAfter else {
        return "the provider asked to be left alone for a while"
      }
      return "the provider asked to be left alone for \(retryAfter.components.seconds) seconds"
    case .malformedResponse(let detail):
      return "the provider answered with something this build cannot use — \(safe(detail))"
    case .grantRejected(let detail):
      return "the provider refused the authorization — \(safe(detail))"
    case .transport(let detail):
      return "the attempt did not complete — \(safe(detail))"
    }
  }

  /// The last thing between a remote answer and the owner's terminal. Detail strings arrive already
  /// sanitized by the wire layer, and sanitizing again here costs nothing and makes that a property
  /// of whatever renders rather than a promise made somewhere upstream — which is the only form of
  /// it that survives a new caller.
  static func safe(_ detail: String) -> String {
    ChatGPTProviderMetadata.safeDiagnostic(detail, redacting: [])
  }
}
