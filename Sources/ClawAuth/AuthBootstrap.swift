import ClawCore
import Foundation

/// The only configuration an auth command reads.
///
/// It is deliberately not `AppConfig`. Login has to be able to discover a model *before* any model
/// is configured, and status has to be able to explain a credential on an installation whose
/// allowlist, base URL, budget, or scheduler config the daemon would refuse to boot on — diagnosing
/// auth is most valuable exactly when something else is broken. So this resolves the state root
/// through the same shared rule daemon config uses, reads the raw model reference, and stops.
public struct AuthBootstrap: Sendable, Equatable {
  public let stateRoot: URL

  /// `CLAW_LLM_MODEL` exactly as the environment spells it, unvalidated and possibly naming another
  /// route's model or no usable model at all. What a reference means is selection's question and
  /// status's; a bootstrap that refused one would be the very failure it exists to survive.
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
