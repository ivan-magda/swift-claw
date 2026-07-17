import ArgumentParser
import ClawCore
import ClawGateway
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

      try Self.sealUnderInstanceLock(secrets, stateRoot: config.stateRoot)

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

// MARK: - Seal

extension SecretsCommand.Seal {
  /// Seals while holding the state-root instance lock, so a concurrent seal-capable command — another
  /// `secrets seal`, an `auth login`, or a running daemon — cannot race the key-adoption-and-rollback
  /// window that a lone seal defends only against itself: without serialization a losing seal can
  /// adopt the winner's key inode and then be orphaned when the winner's rollback unlinks it. The lock
  /// is released the moment the seal returns.
  static func sealUnderInstanceLock(_ secrets: Secrets, stateRoot: URL) throws {
    let lock = try acquireInstanceLockOrExit(stateRoot: stateRoot)
    defer { lock.release() }

    // The same hardened operation the login transition runs: it publishes crash-safely, proves the
    // result decrypts, and unwinds anything it created if it cannot.
    do {
      try EncryptedFileSecretStore.seal(secrets, stateRoot: stateRoot)
    } catch let error {
      FileHandle.standardError.write(Data("secrets seal failed: \(error)\n".utf8))
      throw ExitCode(error.exitCode)
    }
  }

  /// Takes the single-instance lock the daemon and the login transition also hold; a held lock exits
  /// with the daemon's own already-running code, so a supervisor treats it as non-retryable.
  static func acquireInstanceLockOrExit(stateRoot: URL) throws -> InstanceLock {
    let lockPath = SecretStatePaths(stateRoot: stateRoot).instanceLock.path
    do {
      return try InstanceLock(path: lockPath)
    } catch InstanceLock.LockError.alreadyLocked {
      FileHandle.standardError.write(
        Data(
          "secrets seal: another clawd process holds the state-root lock; stop it before sealing\n"
            .utf8
        )
      )
      throw ExitCode(ClawExitCode.alreadyRunning.rawValue)
    }
  }
}
