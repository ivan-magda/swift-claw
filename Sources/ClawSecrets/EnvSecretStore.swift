import ClawCore
import Foundation

/// The sanctioned dev fallback: reads the plaintext env vars and **warns loudly** that secrets
/// are plaintext. Selected only when no encrypted artifact exists (resolver).
public struct EnvSecretStore: SecretStore {
  public enum EnvKey {
    public static let botToken = "CLAW_TELEGRAM_BOT_TOKEN"
    public static let llmApiKey = "CLAW_LLM_API_KEY"
    public static let searchApiKey = "CLAW_SEARCH_API_KEY"
    public static let llmFallbackApiKey = "CLAW_LLM_FALLBACK_API_KEY"

    /// Every variable `loadSecrets` seals, in the order an owner meets them in `.env.example`.
    /// `clawd secrets seal` blanks exactly this list and names exactly this list when it cannot,
    /// so a secret can never reach the envelope while its plaintext line survives unmentioned.
    public static let sealed = [botToken, llmApiKey, searchApiKey, llmFallbackApiKey]
  }

  private let environment: [String: String]
  private let warn: @Sendable (String) -> Void

  public init(
    environment: [String: String],
    warn: @escaping @Sendable (String) -> Void = EnvSecretStore.defaultWarn
  ) {
    self.environment = environment
    self.warn = warn
  }

  public func loadSecrets() throws -> Secrets {
    guard let botToken = environment[EnvKey.botToken], !botToken.isEmpty else {
      throw SecretStoreError.missingTelegramToken
    }

    warn(
      "secrets are PLAINTEXT in environment variables — run `clawd secrets seal` for encrypted-at-rest storage"
    )

    let apiKey = environment[EnvKey.llmApiKey].flatMap { $0.isEmpty ? nil : $0 }
    let searchKey = environment[EnvKey.searchApiKey].flatMap { $0.isEmpty ? nil : $0 }
    let fallbackApiKey = environment[EnvKey.llmFallbackApiKey].flatMap { $0.isEmpty ? nil : $0 }

    return Secrets(
      telegramBotToken: botToken,
      llmApiKey: apiKey,
      searchApiKey: searchKey,
      llmFallbackApiKey: fallbackApiKey
    )
  }

  /// Writes to stderr — used as the default warn so the daemon always emits the warning
  /// even when no custom handler is injected.
  public static let defaultWarn: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data(("WARN: " + message + "\n").utf8))
  }
}
