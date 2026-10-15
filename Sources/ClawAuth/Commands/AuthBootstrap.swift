import ClawCore
import Foundation

public struct AuthBootstrap: Sendable, Equatable {
  public let stateRoot: URL
  public let configuredModel: String?
  public let configuredReasoningEffort: LLMReasoningEffort?

  public init(
    stateRoot: URL,
    configuredModel: String?,
    configuredReasoningEffort: LLMReasoningEffort?
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
    let stateRoot = try StateRootResolver.createStateRoot(for: env[AppConfig.EnvKey.stateRoot])
    let configuredModel = env[AppConfig.EnvKey.llmModel]

    let rawReasoningEffort = env[AppConfig.EnvKey.llmReasoningEffort]
    let configuredReasoningEffort = rawReasoningEffort.flatMap { value in
      LLMReasoningEffort(rawValue: value.trimmingCharacters(in: .whitespaces))
    }

    return AuthBootstrap(
      stateRoot: stateRoot,
      configuredModel: configuredModel,
      configuredReasoningEffort: configuredReasoningEffort
    )
  }
}
