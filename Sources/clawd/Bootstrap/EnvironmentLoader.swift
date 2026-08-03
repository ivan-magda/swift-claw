import ClawCore
import ClawData
import ClawSecrets
import ClawWorkspace
import Foundation

/// The single implementation of each environment-bootstrap step shared by `run` and `doctor`.
/// `run` consumes the steps through its `*OrExit` wrappers (mapping each failure to a distinct
/// exit code); `doctor` calls them individually so it can keep reporting per-row diagnostics.
enum EnvironmentLoader {
  /// Loads and validates config from the process environment.
  static func loadConfig(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> AppConfig {
    try AppConfig.load(environment: environment)
  }

  /// Loads secrets via the fail-closed resolver.
  static func loadSecrets(
    config: AppConfig,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Secrets {
    let resolution = SecretStoreResolver.resolve(
      stateRoot: config.stateRoot,
      environment: environment
    )
    return try resolution.store.loadSecrets()
  }

  /// Reads the owner's MCP server catalog. A file the owner named by env var and that cannot be read
  /// is their error; the probed default simply being absent is how the feature stays off.
  static func loadMCPConfig(config: AppConfig) throws -> MCPConfig {
    try MCPConfigLoader.load(from: config.mcpConfigSource)
  }

  /// Reads the token bound to each configured server in one pass, so the envelope opens once. Every
  /// declared server gets an outcome, disabled ones included — doctor reports on the whole file.
  static func loadMCPCredentials(
    config: AppConfig,
    servers: [MCPServerConfig]
  ) throws(CredentialStoreError) -> [String: MCPCredentialLoad] {
    return try EncryptedMCPCredentialStore(stateRoot: config.stateRoot).loadAll(servers: servers)
  }

  /// Opens the store bundle at the state root's database path (runs pending migrations).
  static func openStores(config: AppConfig) throws -> ClawStores {
    try ClawDatabase.openStores(path: databasePath(config: config))
  }

  /// Creates the workspace directory (0700) if missing.
  static func ensureWorkspaceDirectory(config: AppConfig) throws {
    try FileSystemWorkspace(root: workspaceRoot(config: config)).ensureRootExists()
  }

  static func databasePath(config: AppConfig) -> String {
    config.stateRoot.appendingPathComponent(StateFile.database).path
  }

  static func workspaceRoot(config: AppConfig) -> URL {
    config.stateRoot.appendingPathComponent(StateFile.workspace, isDirectory: true)
  }
}
