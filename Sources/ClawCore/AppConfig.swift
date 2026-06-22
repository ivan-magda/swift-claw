import Foundation

public struct AppConfig: Sendable, Equatable {
  enum EnvKey {
    static let botToken = "CLAW_TELEGRAM_BOT_TOKEN"
    static let allowlist = "CLAW_ALLOWLIST"
    static let stateRoot = "CLAW_STATE_ROOT"
    static let pollTimeout = "CLAW_POLL_TIMEOUT"
    static let llmBaseURL = "CLAW_LLM_BASE_URL"
    static let llmModel = "CLAW_LLM_MODEL"
    static let llmApiKey = "CLAW_LLM_API_KEY"
    static let llmMaxTokensField = "CLAW_LLM_MAX_TOKENS_FIELD"
    static let llmMaxTokens = "CLAW_LLM_MAX_TOKENS"
  }

  private enum EnvDefaults {
    static let pollTimeoutSeconds = 30
    static let stateDirectoryName = ".swift-claw"
    static let maxTokensField = MaxTokensField.maxCompletionTokens
    static let maxOutputTokens = 4096
    static let retryBudget = 3
    static let requestTimeoutSeconds = 180
  }

  private static let stateRootPermissions = 0o700

  public let botToken: String
  public let allowlist: Set<Int64>
  public let stateRoot: URL
  public let pollTimeoutSeconds: Int
  public let llm: LLMConfig

  public init(
    botToken: String,
    allowlist: Set<Int64>,
    stateRoot: URL,
    pollTimeoutSeconds: Int,
    llm: LLMConfig
  ) {
    self.botToken = botToken
    self.allowlist = allowlist
    self.stateRoot = stateRoot
    self.pollTimeoutSeconds = pollTimeoutSeconds
    self.llm = llm
  }

  /// Loads and validates config from the environment, throwing `ConfigError` on a missing token,
  /// a non-numeric allowlist entry, an uncreatable state root, or missing/invalid LLM settings.
  /// An empty allowlist is allowed so onboarding can still boot.
  public static func load(environment env: [String: String]) throws -> AppConfig {
    guard let botToken = env[EnvKey.botToken], !botToken.isEmpty else {
      throw ConfigError.missingBotToken
    }

    let allowlist = try parseAllowlist(from: env[EnvKey.allowlist])
    let stateRoot = try createStateRootURL(for: env[EnvKey.stateRoot])
    let pollTimeoutSeconds =
      env[EnvKey.pollTimeout].flatMap(Int.init) ?? EnvDefaults.pollTimeoutSeconds
    // Parsed last so a missing LLM key never preempts the bot-token / allowlist errors.
    let llm = try parseLLMConfig(from: env)

    return AppConfig(
      botToken: botToken,
      allowlist: allowlist,
      stateRoot: stateRoot,
      pollTimeoutSeconds: pollTimeoutSeconds,
      llm: llm
    )
  }

  /// `apiKey` is optional — local servers need none.
  private static func parseLLMConfig(from env: [String: String]) throws -> LLMConfig {
    guard
      let baseURL = env[EnvKey.llmBaseURL]?.trimmingCharacters(in: .whitespaces),
      !baseURL.isEmpty
    else {
      throw ConfigError.missingLLMBaseURL
    }

    guard
      let model = env[EnvKey.llmModel]?.trimmingCharacters(in: .whitespaces),
      !model.isEmpty
    else {
      throw ConfigError.missingLLMModel
    }

    let apiKey = env[EnvKey.llmApiKey] ?? ""

    let rawField = env[EnvKey.llmMaxTokensField]?.trimmingCharacters(in: .whitespaces) ?? ""
    let maxTokensField: MaxTokensField
    if rawField.isEmpty {
      maxTokensField = EnvDefaults.maxTokensField
    } else if let parsedField = MaxTokensField(rawValue: rawField) {
      maxTokensField = parsedField
    } else {
      throw ConfigError.invalidMaxTokensField(rawField)
    }

    let rawMaxTokens = env[EnvKey.llmMaxTokens]?.trimmingCharacters(in: .whitespaces) ?? ""
    let maxOutputTokens: Int
    if rawMaxTokens.isEmpty {
      maxOutputTokens = EnvDefaults.maxOutputTokens
    } else if let parsedMaxTokens = Int(rawMaxTokens), parsedMaxTokens > 0 {
      maxOutputTokens = parsedMaxTokens
    } else {
      throw ConfigError.invalidMaxTokens(rawMaxTokens)
    }

    return LLMConfig(
      baseURL: baseURL,
      model: model,
      apiKey: apiKey,
      maxTokensField: maxTokensField,
      maxOutputTokens: maxOutputTokens,
      retryBudget: EnvDefaults.retryBudget,
      requestTimeoutSeconds: EnvDefaults.requestTimeoutSeconds
    )
  }

  private static func parseAllowlist(from environmentValue: String?) throws -> Set<Int64> {
    guard
      let environmentValue = environmentValue?.trimmingCharacters(in: .whitespaces),
      !environmentValue.isEmpty
    else {
      return []
    }

    var allowlist = Set<Int64>()

    for part in environmentValue.split(separator: ",") {
      let trimmed = part.trimmingCharacters(in: .whitespaces)

      guard let id = Int64(trimmed) else {
        throw ConfigError.invalidAllowlist(trimmed)
      }

      allowlist.insert(id)
    }

    return allowlist
  }

  private static func createStateRootURL(for rawPath: String?) throws -> URL {
    let trimmedPath = rawPath?.trimmingCharacters(in: .whitespaces)
    let stateRootURL =
      if let path = trimmedPath, !path.isEmpty {
        URL(fileURLWithPath: path, isDirectory: true)
      } else {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          EnvDefaults.stateDirectoryName
        )
      }

    do {
      try FileManager.default.createDirectory(
        at: stateRootURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: stateRootPermissions]
      )
    } catch {
      throw ConfigError.unwritableStateRoot(stateRootURL.path)
    }

    return stateRootURL
  }
}
