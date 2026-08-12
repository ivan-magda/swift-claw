import ClawCore
import Foundation

public struct AuthBootstrap: Sendable, Equatable {
  public let stateRoot: URL
  public let configuredModel: String?

  public init(stateRoot: URL, configuredModel: String?) {
    self.stateRoot = stateRoot
    self.configuredModel = configuredModel
  }

  /// Resolves from a supplied environment rather than the process's own, so nothing here depends on
  /// how the owner's shell happened to be started, and nothing is exported back.
  ///
  /// - Throws: `ConfigError.unwritableStateRoot` when the state root cannot be created.
  public static func resolve(environment env: [String: String]) throws -> AuthBootstrap {
    AuthBootstrap(
      stateRoot: try StateRootResolver.createStateRoot(for: env[AppConfig.EnvKey.stateRoot]),
      configuredModel: env[AppConfig.EnvKey.llmModel]
    )
  }
}
