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

    @Option(
      name: .customLong("env-file"),
      help:
        "Env file to scrub sealed secrets from (default: $CLAW_ENV_FILE or ~/.swift-claw/clawd.env)."
    )
    var envFile: String?

    @Flag(name: .customLong("no-scrub"), help: "Leave plaintext secret lines in the env file.")
    var noScrub = false

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
      let scrubOutcome: SealScrubOutcome? =
        noScrub
        ? nil
        : Self.scrubEnvFile(
          at: resolvedEnvFilePath(environment: environment),
          keys: [
            EnvSecretStore.EnvKey.botToken,
            EnvSecretStore.EnvKey.llmApiKey,
            EnvSecretStore.EnvKey.searchApiKey,
          ]
        )
      // swiftlint:disable:next no_print_in_production
      print(
        Self.sealSummary(envelopePath: envelopePath, keyPath: keyPath, scrubOutcome: scrubOutcome)
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

// MARK: - Env-File Scrub

enum SealScrubOutcome: Equatable {
  case scrubbed(keys: [String], path: String)
  case alreadyClean(path: String)
  case fileAbsent(path: String)
  case failed(path: String, reason: String)
}

extension SecretsCommand.Seal {
  func resolvedEnvFilePath(environment: [String: String]) -> String {
    if let explicit = envFile { return explicit }
    if let fromEnv = environment["CLAW_ENV_FILE"] { return fromEnv }
    return NSHomeDirectory() + "/.swift-claw/clawd.env"
  }

  /// Blanks sealed secret values in the env file, writing atomically and preserving 0600.
  static func scrubEnvFile(at path: String, keys: [String]) -> SealScrubOutcome {
    guard FileManager.default.fileExists(atPath: path) else {
      return .fileAbsent(path: path)
    }

    guard
      let data = FileManager.default.contents(atPath: path),
      let contents = String(data: data, encoding: .utf8)
    else {
      return .failed(path: path, reason: "unreadable or not UTF-8")
    }

    let result = EnvFileSecretScrubber.scrub(contents: contents, keys: keys)
    guard !result.scrubbedKeys.isEmpty else {
      return .alreadyClean(path: path)
    }

    let tempPath = "\(path).seal-scrub.tmp"
    do {
      try result.contents.write(toFile: tempPath, atomically: false, encoding: .utf8)

      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: tempPath
      )

      _ = try FileManager.default.replaceItemAt(
        URL(fileURLWithPath: path),
        withItemAt: URL(fileURLWithPath: tempPath)
      )
    } catch {
      try? FileManager.default.removeItem(atPath: tempPath)
      return .failed(path: path, reason: "\(error)")
    }

    return .scrubbed(keys: result.scrubbedKeys, path: path)
  }

  static func sealSummary(
    envelopePath: String,
    keyPath: String,
    scrubOutcome: SealScrubOutcome?
  ) -> String {
    var summary = """
      Sealed secrets → \(envelopePath)
      Key → \(keyPath) (mode 0600 — keep this OUTSIDE your state-root backup boundary)
      """

    let manualNote = """
      Remove the plaintext \(EnvSecretStore.EnvKey.botToken) / \
      \(EnvSecretStore.EnvKey.llmApiKey) / \(EnvSecretStore.EnvKey.searchApiKey) \
      values from your env file yourself.
      """

    switch scrubOutcome {
    case .scrubbed(let keys, let path):
      summary += "\nBlanked \(keys.joined(separator: ", ")) in \(path)."
      summary += "\nYour current shell still holds the old values; open a fresh shell "
      summary += "before running the daemon."
    case .alreadyClean(let path):
      summary += "\nNo plaintext secret values found in \(path)."
    case .fileAbsent(let path):
      summary += "\nNo env file at \(path) — nothing to scrub. " + manualNote
    case .failed(let path, let reason):
      summary += "\nWARNING: could not scrub \(path) (\(reason))."
      summary += "\nThe plaintext secret values are still in \(path) — " + manualNote
    case nil:
      summary += "\n" + manualNote
    }

    return summary
  }
}
