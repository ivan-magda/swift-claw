import Foundation

/// The secrets seam. Secrets load **once at startup** into an immutable `Sendable` value so they
/// cross actor/task boundaries freely (impl-grounding §3.5). The concrete stores live in `ClawSecrets`.
public protocol SecretStore: Sendable {
  func loadSecrets() throws -> Secrets
}

/// The loaded secrets. These values feed the exact-value redactors: `TelegramClient` (bot token),
/// `OpenAICompatibleProvider` (LLM key), and — from 3b — the ClawTools `SecretRedactor` and the
/// search client (`searchApiKey`).
public struct Secrets: Sendable, Equatable {
  public let telegramBotToken: String
  public let llmApiKey: String?
  public let searchApiKey: String?

  public init(telegramBotToken: String, llmApiKey: String?, searchApiKey: String? = nil) {
    self.telegramBotToken = telegramBotToken
    self.llmApiKey = llmApiKey
    self.searchApiKey = searchApiKey
  }

  /// The concrete secret strings an exact-value redactor should scrub — from tool output
  /// (`SecretRedactor`) and from developer logs (the log-handler redactor). One source of truth so
  /// the two call sites can never drift on what counts as a secret.
  public var redactionValues: [String] {
    [telegramBotToken, llmApiKey, searchApiKey].compactMap { value in value }
  }
}

/// State-root-relative filenames the encrypted backend owns. Shared so the resolver's existence
/// checks and the `secrets seal` subcommand name the same files the store reads.
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

  public var exitCode: Int32 { ClawExitCode.secretLoadFailed.rawValue }
}
