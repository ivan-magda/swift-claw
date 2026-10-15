import ClawCore
import Foundation

public struct AuthBootstrap: Sendable, Equatable {
  public let stateRoot: URL
  public let configuredModel: String?
  /// The configured level only when it is a word clawd accepts. A misspelled one stays unmarked here
  /// and fails configuration at boot, which is where the owner is told about it.
  public let configuredReasoningEffort: LLMReasoningEffort?

  public init(
    stateRoot: URL,
    configuredModel: String?,
    configuredReasoningEffort: LLMReasoningEffort? = nil
  ) {
    self.stateRoot = stateRoot
    self.configuredModel = configuredModel
    self.configuredReasoningEffort = configuredReasoningEffort
  }

  /// Resolves from a supplied environment rather than the process's own, so nothing here depends on
  /// how the owner's shell happened to be started, and nothing is exported back.
  ///
  /// - Throws: `ConfigError.unwritableStateRoot` when the state root cannot be created.
  public static func resolve(environment env: [String: String]) throws -> AuthBootstrap {
    AuthBootstrap(
      stateRoot: try StateRootResolver.createStateRoot(for: env[AppConfig.EnvKey.stateRoot]),
      configuredModel: env[AppConfig.EnvKey.llmModel],
      configuredReasoningEffort: env[AppConfig.EnvKey.llmReasoningEffort].flatMap { raw in
        LLMReasoningEffort(rawValue: raw.trimmingCharacters(in: .whitespaces))
      }
    )
  }
}
