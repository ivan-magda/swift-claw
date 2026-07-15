import ClawSecrets

/// State-root-relative names the daemon owns. The instance lock is not among them: the mutating
/// auth commands must hold it to touch the encrypted artifacts, so `SecretStatePaths` names it and
/// this enum defers.
enum StateFile {
  static let database = "claw.sqlite"
  static let lock = SecretStatePaths.instanceLockName
  static let workspace = "workspace"
}
