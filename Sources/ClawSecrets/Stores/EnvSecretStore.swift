import ClawCore
import Foundation

/// The sanctioned dev fallback: reads the plaintext env vars and **warns loudly** that secrets
/// are plaintext. Selected only when no encrypted artifact exists (resolver).
public struct EnvSecretStore: SecretStore {
  public enum EnvKey {
    public static let botToken = "CLAW_TELEGRAM_BOT_TOKEN"
    public static let llmAPIKey = "CLAW_LLM_API_KEY"
    public static let searchAPIKey = "CLAW_SEARCH_API_KEY"
    public static let llmFallbackAPIKey = "CLAW_LLM_FALLBACK_API_KEY"

    /// Every variable `loadSecrets` seals, in the order an owner meets them in `.env.example`.
    /// `clawd secrets seal` blanks exactly this list and names exactly this list when it cannot,
    /// so a secret can never reach the envelope while its plaintext line survives unmentioned.
    public static let sealed = [botToken, llmAPIKey, searchAPIKey, llmFallbackAPIKey]
  }

  private let environment: [String: String]
  private let warn: @Sendable (_ message: String) -> Void

  public init(
    environment: [String: String],
    warn: @escaping @Sendable (_ message: String) -> Void = EnvSecretStore.defaultWarn
  ) {
    self.environment = environment
    self.warn = warn
  }

  public func loadSecrets() throws -> Secrets {
    let secrets = try Secrets(
      validatingTelegramBotToken: environment[EnvKey.botToken],
      llmAPIKey: environment[EnvKey.llmAPIKey],
      searchAPIKey: environment[EnvKey.searchAPIKey],
      llmFallbackAPIKey: environment[EnvKey.llmFallbackAPIKey]
    )

    warn(
      """
      secrets are PLAINTEXT in environment variables — \
      run `clawd secrets seal` for encrypted-at-rest storage
      """
    )

    return secrets
  }

  /// Writes to stderr — used as the default warn so the daemon always emits the warning
  /// even when no custom handler is injected.
  public static let defaultWarn: @Sendable (_ message: String) -> Void = { message in
    FileHandle.standardError.write(Data("WARN: \(message)\n".utf8))
  }
}
