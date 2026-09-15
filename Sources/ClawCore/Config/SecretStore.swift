import Foundation

/// Loads the immutable secrets shared across tasks after startup.
///
/// Secrets load once at startup; concrete stores live in `ClawSecrets`.
public protocol SecretStore: Sendable {
  func loadSecrets() throws -> Secrets
}

/// The loaded secrets.
///
/// These values feed the exact-value redactors: `TelegramClient` (bot token),
/// `OpenAICompatibleProvider` (LLM key), and the `SecretRedactor` and the search client
/// (`searchAPIKey`).
public struct Secrets: Sendable, Equatable {
  public let telegramBotToken: String
  public let llmAPIKey: String?
  public let searchAPIKey: String?
  public let llmFallbackAPIKey: String?

  public init(
    telegramBotToken: String,
    llmAPIKey: String?,
    searchAPIKey: String? = nil,
    llmFallbackAPIKey: String? = nil
  ) {
    self.telegramBotToken = telegramBotToken
    self.llmAPIKey = llmAPIKey
    self.searchAPIKey = searchAPIKey
    self.llmFallbackAPIKey = llmFallbackAPIKey
  }

  /// The concrete secret strings an exact-value redactor should scrub — from tool output
  /// (`SecretRedactor`) and from developer logs (the log-handler redactor).
  ///
  /// One source of truth so the two call sites can never drift on what counts as a secret.
  public var redactionValues: [String] {
    [telegramBotToken, llmAPIKey, searchAPIKey, llmFallbackAPIKey].compactMap {
      $0
    }
  }
}

/// State-root-relative filenames the encrypted backend owns.
///
/// Shared so the resolver's existence checks and the `secrets seal` subcommand name the same files
/// the store reads.
public enum SecretFile {
  public static let envelope = "secrets.enc"
  public static let key = "secret.key"
}

/// Every secret-load failure is non-retryable and exits 11 — distinct from a config error so the
/// supervisor backs off instead of hot-looping (`ClawExitCode.secretLoadFailed`).
public enum SecretStoreError: Error, Sendable, Equatable {
  case missingTelegramToken
  case keyFileInsecure(String)
  case malformedEnvelope
  case decryptionFailed
  case unreadable(String)
  /// An encrypted artifact could not be written, or was written but not proven durable.
  ///
  /// The owner's remedy is the same either way — rerun the seal — so the two are not modelled apart
  /// here.
  case publicationFailed(String)

  public var exitCode: Int32 {
    ClawExitCode.secretLoadFailed.rawValue
  }
}
