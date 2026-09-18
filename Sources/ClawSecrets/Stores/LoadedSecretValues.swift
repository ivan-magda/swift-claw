import ClawCore

extension Secrets {
  /// Validates loaded runtime secrets without trimming or otherwise changing credential bytes.
  /// The Telegram token is required; exactly empty optional API keys mean no credential.
  init(
    validatingTelegramBotToken telegramBotToken: String?,
    llmAPIKey: String?,
    searchAPIKey: String?,
    llmFallbackAPIKey: String?
  ) throws(SecretStoreError) {
    guard let telegramBotToken, telegramBotToken.isEmpty == false else {
      throw .missingTelegramToken
    }
    self.init(
      telegramBotToken: telegramBotToken,
      llmAPIKey: Self.optionalAPIKey(llmAPIKey),
      searchAPIKey: Self.optionalAPIKey(searchAPIKey),
      llmFallbackAPIKey: Self.optionalAPIKey(llmFallbackAPIKey)
    )
  }
}

// MARK: - Optional Credentials

private extension Secrets {
  static func optionalAPIKey(_ value: String?) -> String? {
    value.flatMap { key in
      key.isEmpty ? nil : key
    }
  }
}
