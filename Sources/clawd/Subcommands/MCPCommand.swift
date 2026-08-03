import ArgumentParser
import AsyncHTTPClient
import ClawAuth
import ClawCore
import ClawGateway
import ClawSecrets
import ClawTelegram
import ClawWorkspace
import Foundation
import Logging

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

// MARK: - Command

struct MCPCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Manage the assistant's MCP servers.",
    subcommands: [List.self, Probe.self, SetToken.self, ClearToken.self]
  )

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "Show the configured MCP servers and their token state.",
      discussion: """
        A static check: it reads the catalog and the token store and contacts nothing, so it answers \
        the same way whether the daemon is up, down, or the servers are unreachable. Use probe for \
        live proof.
        """
    )

    func run() throws {
      let environment = ProcessInfo.processInfo.environment
      let context = try MCPCommand.resolveContext(environment: environment)
      MCPCommand.emit(try MCPCommand.listReport(context: context))
    }
  }

  struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "probe",
      abstract: "Contact each MCP server and report what it answers.",
      discussion: """
        Connects, runs the initialize handshake, and counts the tools the server would contribute — \
        the same path the daemon takes at boot, so a server that probes clean is a server that will \
        load. Exits non-zero when any probed server fails.
        """
    )

    @Argument(help: "Probe only this server. Omitted, every enabled server is probed.")
    var server: String?

    func run() async throws {
      let environment = ProcessInfo.processInfo.environment
      let context = try MCPCommand.resolveContext(environment: environment)
      let targets = try MCPCommand.probeTargets(named: server, config: context.config)

      guard targets.isEmpty == false else {
        MCPCommand.emit(MCPCommand.nothingToProbeReport(config: context.config))
        return
      }

      let report = try await MCPCommand.probeReport(targets: targets, context: context)
      MCPCommand.emit(report)
      guard report.ok else {
        throw ExitCode.failure
      }
    }
  }

  struct SetToken: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "set-token",
      abstract: "Store the access token for a configured MCP server.",
      discussion: """
        The token is read from stdin — piped, or typed at the prompt — never from the command line, \
        where it would land in the shell history and the process table. Stop the daemon first: the \
        token is read once at boot.
        """
    )

    @Argument(help: "Server name as it appears in the MCP config.")
    var server: String

    func run() throws {
      let environment = ProcessInfo.processInfo.environment
      let context = try MCPCommand.resolveContext(environment: environment)
      let token = try MCPCommand.readToken(for: server)
      MCPCommand.report(try MCPCommand.setToken(token, server: server, context: context))
    }
  }

  struct ClearToken: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "clear-token",
      abstract: "Remove the stored access token for an MCP server.",
      discussion: """
        Takes a bare name rather than a configured server, so a token left behind by a server the \
        owner has since removed can still be cleared.
        """
    )

    @Argument(help: "Server name the token was stored under.")
    var server: String

    func run() throws {
      let environment = ProcessInfo.processInfo.environment
      let stateRoot = try MCPCommand.resolveStateRoot(environment: environment)
      MCPCommand.report(try MCPCommand.clearToken(server: server, stateRoot: stateRoot))
    }
  }
}

// MARK: - Outcomes

/// What a token verb did, apart from how it is printed. Keeping the two apart is what lets the verbs
/// be driven by a test without a terminal, a pipe, or a process exit.
enum MCPTokenOutcome: Equatable {
  case stored(server: String)
  case cleared(server: String)
  /// Nothing was stored under that name, so nothing was removed. Not a failure: the state the owner
  /// asked for is the state they have.
  case nothingToClear(server: String)

  var summary: String {
    switch self {
    case .stored(let server):
      return """
        Stored the access token for MCP server '\(server)'.
        It is bound to that server's configured URL — re-run set-token if you re-point the server.
        Restart clawd to pick it up.
        """
    case .cleared(let server):
      return "Removed the stored access token for MCP server '\(server)'."
    case .nothingToClear(let server):
      return "No access token was stored for MCP server '\(server)'."
    }
  }
}

/// The state root and the catalog the token verbs act against.
struct MCPCommandContext {
  let stateRoot: URL
  let config: MCPConfig
}

// MARK: - Verbs

extension MCPCommand {
  /// Binds a token to the named server's configured URL, under the daemon's instance lock.
  ///
  /// The server must be in the config, because its URL is what the token is bound to: a record with
  /// no binding is a secret at rest that no request could ever be allowed to use.
  static func setToken(
    _ token: String,
    server name: String,
    context: MCPCommandContext
  ) throws -> MCPTokenOutcome {
    guard let server = context.config.servers.first(where: { $0.name == name }) else {
      throw fail(
        MCPConfigError.unknownServer(name: name, known: context.config.servers.map(\.name))
      )
    }

    return try underInstanceLock(stateRoot: context.stateRoot) {
      try EncryptedMCPCredentialStore(stateRoot: context.stateRoot).save(
        token: token,
        for: server
      )
      return .stored(server: server.name)
    }
  }

  /// The offline view: what the catalog declares, what the token store holds for it, and any token
  /// left behind by a server the catalog no longer names. Contacts nothing.
  static func listReport(context: MCPCommandContext) throws -> DoctorReport {
    let store = EncryptedMCPCredentialStore(stateRoot: context.stateRoot)
    let credentials = try openingTokenStore {
      try store.loadAll(servers: context.config.servers)
    }
    let stored = try openingTokenStore {
      try store.storedServerNames()
    }

    var checks = MCPDoctorRows.rows(config: context.config, credentials: credentials)
    if let orphans = MCPDoctorRows.orphanTokenRow(storedServers: stored, config: context.config) {
      checks.append(orphans)
    }
    return DoctorReport(checks: checks)
  }

  /// The servers a probe contacts: the one named, or every enabled server. A server named outright
  /// is probed even when it is disabled — the owner asked about that one.
  static func probeTargets(named name: String?, config: MCPConfig) throws -> [MCPServerConfig] {
    guard let name else {
      return config.enabledServers
    }
    guard let server = config.servers.first(where: { $0.name == name }) else {
      throw fail(MCPConfigError.unknownServer(name: name, known: config.servers.map(\.name)))
    }
    return [server]
  }

  /// Live proof: every target contacted over the real transport, reported in the same vocabulary the
  /// daemon records at boot.
  static func probeReport(
    targets: [MCPServerConfig],
    context: MCPCommandContext
  ) async throws -> DoctorReport {
    let credentials = try openingTokenStore {
      try EncryptedMCPCredentialStore(stateRoot: context.stateRoot).loadAll(servers: targets)
    }

    // The daemon's own tool client posture, not the library default: a probe run over a
    // redirect-following client with decompression off would be proving something about a road the
    // daemon never takes.
    let client = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: HTTPClientProfile.protectedEgress.configuration
    )
    let outcomes = await MCPProbe.run(
      servers: targets,
      credentials: credentials,
      http: AsyncHTTPExecutor(client: client),
      logger: MCPProbe.quietLogger()
    )
    try? await client.shutdown()

    return DoctorReport(checks: MCPDoctorRows.bootRows(outcomes: outcomes))
  }

  static func nothingToProbeReport(config: MCPConfig) -> DoctorReport {
    DoctorReport(checks: [MCPDoctorRows.nothingProbedRow(config: config)])
  }

  static func clearToken(server name: String, stateRoot: URL) throws -> MCPTokenOutcome {
    try underInstanceLock(stateRoot: stateRoot) {
      let removed = try EncryptedMCPCredentialStore(stateRoot: stateRoot).delete(server: name)
      return removed ? .cleared(server: name) : .nothingToClear(server: name)
    }
  }
}

// MARK: - Token Store

private extension MCPCommand {
  /// Runs a read against the token store, mapping its closed taxonomy to the exit code the owner
  /// gets for any unopenable envelope. The read-only verbs take no lock: the daemon writes nothing
  /// there, so the worst a concurrent mutation can do is answer from the previous envelope.
  static func openingTokenStore<Value>(_ body: () throws -> Value) throws -> Value {
    do {
      return try body()
    } catch let error as CredentialStoreError {
      throw fail("token store: \(error)", code: .secretLoadFailed)
    }
  }
}

// MARK: - Instance Lock

private extension MCPCommand {
  /// Runs `body` while holding the state root's single-instance lock, so a token cannot be rewritten
  /// under a daemon that has already read the old one — it loads credentials once at boot.
  static func underInstanceLock(
    stateRoot: URL,
    _ body: () throws -> MCPTokenOutcome
  ) throws -> MCPTokenOutcome {
    let lease: AuthMutationLease
    do {
      lease = try InstanceLockAdapter(stateRoot: stateRoot).acquire()
    } catch AuthMutationLockFailure.held {
      throw fail(
        "another clawd process holds the state-root lock; stop the daemon before changing tokens",
        code: .alreadyRunning
      )
    } catch {
      throw fail("cannot take the state-root lock: \(error)", code: .alreadyRunning)
    }
    defer { lease.release() }

    do {
      return try body()
    } catch let error as CredentialStoreError {
      throw fail("token store: \(error)", code: .secretLoadFailed)
    }
  }
}

// MARK: - Resolution

private extension MCPCommand {
  /// Resolves the state root and the catalog without loading the whole `AppConfig`: an owner
  /// repairing a token must not be blocked by an unrelated env var the daemon would refuse to boot
  /// on. A malformed catalog is still fatal here, because it is the file naming the server.
  static func resolveContext(environment: [String: String]) throws -> MCPCommandContext {
    let stateRoot = try resolveStateRoot(environment: environment)
    let source = AppConfig.mcpConfigSource(from: environment, stateRoot: stateRoot)
    do {
      return MCPCommandContext(
        stateRoot: stateRoot,
        config: try MCPConfigLoader.load(from: source)
      )
    } catch let error as MCPConfigError {
      throw fail(error)
    }
  }

  static func resolveStateRoot(environment: [String: String]) throws -> URL {
    do {
      return try StateRootResolver.createStateRoot(for: environment[AppConfig.EnvKey.stateRoot])
    } catch let error as ConfigError {
      throw fail("config error: \(error)", code: ClawExitCode(rawValue: error.exitCode))
    }
  }
}

// MARK: - Terminal

private extension MCPCommand {
  /// Reads the token from stdin: piped when stdin is not a terminal, prompted when it is. Never from
  /// argv, which the shell history and every `ps` on the machine can read.
  ///
  /// The prompt goes to stderr so that stdout carries only the command's own report.
  static func readToken(for server: String) throws -> String {
    let raw: String?
    if isatty(STDIN_FILENO) == 1 {
      FileHandle.standardError.write(Data("Access token for MCP server '\(server)': ".utf8))
      raw = Swift.readLine(strippingNewline: true)
    } else {
      raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
    }

    let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard token.isEmpty == false else {
      throw fail("no token on stdin; nothing was stored", code: .configInvalid)
    }
    return token
  }

  static func report(_ outcome: MCPTokenOutcome) {
    // swiftlint:disable:next no_print_in_production
    print(outcome.summary)
  }

  /// The read-only verbs print the same grouped table `clawd doctor` does, because they are built
  /// from the same rows.
  static func emit(_ report: DoctorReport) {
    // swiftlint:disable:next no_print_in_production
    print(report.renderText())
  }

  /// Writes the complaint to stderr and returns the code to throw, so every refusal reads the same
  /// way and no call site can print without exiting.
  static func fail(_ message: String, code: ClawExitCode?) -> ExitCode {
    FileHandle.standardError.write(Data("mcp: \(message)\n".utf8))
    return ExitCode((code ?? .configInvalid).rawValue)
  }

  static func fail(_ error: MCPConfigError) -> ExitCode {
    fail("\(error)", code: ClawExitCode(rawValue: error.exitCode))
  }
}
