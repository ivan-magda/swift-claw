import ClawCore
import Foundation

/// The §15-sanctioned dev fallback: reads the plaintext env vars (Inc 1 behavior) and **warns
/// loudly** that secrets are plaintext. Selected only when no encrypted artifact exists (resolver).
public struct EnvSecretStore: SecretStore {
  public enum EnvKey {
    public static let botToken = "CLAW_TELEGRAM_BOT_TOKEN"
    public static let llmApiKey = "CLAW_LLM_API_KEY"
    public static let searchApiKey = "CLAW_SEARCH_API_KEY"
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

    return Secrets(
      telegramBotToken: botToken,
      llmApiKey: apiKey,
      searchApiKey: searchKey
    )
  }

  /// Writes to stderr — used as the default warn so the daemon always emits the warning
  /// even when no custom handler is injected.
  public static let defaultWarn: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data(("WARN: " + message + "\n").utf8))
  }
}
