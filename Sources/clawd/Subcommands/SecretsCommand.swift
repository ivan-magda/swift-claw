import ArgumentParser
import ClawCore
import ClawSecrets
import Foundation

struct SecretsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "secrets",
    abstract: "Manage encrypted-at-rest secrets.",
    subcommands: [Seal.self]
  )

  /// Reads the plaintext env secrets and encrypts them into `<stateRoot>/secrets.enc`, generating
  /// `secret.key` (0600) if missing. Uses the same env file the daemon reads (it already carries the
  /// non-secret LLM config needed to resolve the state root).
  struct Seal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Encrypt the env secrets into <stateRoot>/secrets.enc."
    )

    func run() async throws {
      let environment = ProcessInfo.processInfo.environment
      let config: AppConfig
      do {
        config = try AppConfig.load(environment: environment)
      } catch let error as ConfigError {
        FileHandle.standardError.write(Data("secrets seal: config error: \(error)\n".utf8))
        throw ExitCode(error.exitCode)
      }

      let secrets: Secrets
      do {
        // Suppress the plaintext warning — reading plaintext to encrypt it is the intent here.
        secrets = try EnvSecretStore(
          environment: environment,
          warn: { _ in }
        ).loadSecrets()
      } catch let error as SecretStoreError {
        FileHandle.standardError.write(Data("secrets seal: \(error)\n".utf8))
        throw ExitCode(error.exitCode)
      }

      // The same hardened operation the login transition runs: it publishes crash-safely, proves
      // the result decrypts, and unwinds anything it created if it cannot.
      do {
        try EncryptedFileSecretStore.seal(secrets, stateRoot: config.stateRoot)
      } catch let error as SecretStoreError {
        FileHandle.standardError.write(Data("secrets seal failed: \(error)\n".utf8))
        throw ExitCode(error.exitCode)
      }

      let paths = SecretStatePaths(stateRoot: config.stateRoot)
      let envelopePath = paths.runtimeEnvelope.path
      let keyPath = paths.key.path
      // swiftlint:disable:next no_print_in_production
      print(
        """
        Sealed secrets → \(envelopePath)
        Key → \(keyPath) (mode 0600 — keep this OUTSIDE your state-root backup boundary)
        You may now remove the plaintext \(EnvSecretStore.EnvKey.botToken) / \
        \(EnvSecretStore.EnvKey.llmApiKey) /
        \(EnvSecretStore.EnvKey.searchApiKey) from the env.
        """
      )
    }
  }
}
