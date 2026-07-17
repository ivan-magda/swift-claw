import ArgumentParser
import AsyncHTTPClient
import ClawAuth
import ClawCore
import ClawGateway
import ClawSecrets
import ClawTelegram
import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

// MARK: - Provider Selection

/// The provider an auth command acts on.
///
/// Spelled as a type rather than a validated string so that an unknown name is refused by the
/// parser, before `run` exists to do anything about it — which is the only way "no state is touched
/// and no request is made" can be a fact about the command rather than a promise made by its first
/// few lines. The names come from the route registry rather than from literals here, so the value an
/// owner types and the record the credential is stored under cannot drift apart.
enum AuthProvider: CaseIterable, ExpressibleByArgument {
  case openAIChatGPT

  var providerID: LLMProviderID {
    switch self {
    case .openAIChatGPT:
      return ChatGPTProviderMetadata.providerID
    }
  }

  init?(argument: String) {
    guard let match = Self.allCases.first(where: { $0.providerID.rawValue == argument }) else {
      return nil
    }
    self = match
  }

  var defaultValueDescription: String { providerID.rawValue }

  static var allValueStrings: [String] { allCases.map(\.providerID.rawValue) }
}

/// Shared by all three subcommands so the surface cannot drift between them.
struct AuthProviderOptions: ParsableArguments {
  @Option(help: "The provider to act on.")
  var provider: AuthProvider = .openAIChatGPT
}

// MARK: - Command

struct AuthCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "auth",
    abstract: "Manage the assistant's provider credentials.",
    subcommands: [Login.self, Status.self, Logout.self]
  )

  struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Sign in to a provider and choose a model."
    )

    @OptionGroup var options: AuthProviderOptions

    func run() async throws {
      let environment = ProcessInfo.processInfo.environment
      let bootstrap = try AuthCommand.resolveBootstrapOrExit(environment: environment)

      // The only client any auth command opens, and the reason it is opened here rather than in the
      // composition below: login is the one command with a wire step. Nothing between this line and
      // the shutdown can throw — the workflow reports its failures rather than raising them — so the
      // client cannot outlive the command. `defer` could not make that promise, because it cannot
      // await the shutdown, and a dropped client is a hung process rather than a leaked one.
      let httpClient = HTTPClient(
        eventLoopGroupProvider: .singleton,
        configuration: HTTPClientProfile.protectedEgress.configuration
      )
      let result = await AuthCommand.workflow(
        bootstrap: bootstrap,
        environment: environment,
        executor: AsyncHTTPExecutor(client: httpClient)
      ).login()
      // Swallowed on purpose: the owner's login either happened or it did not, and a socket that
      // would not close politely afterwards changes neither the outcome nor what they should do.
      try? await httpClient.shutdown()

      try AuthCommand.finish(result)
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Report the stored credential without contacting the provider."
    )

    @OptionGroup var options: AuthProviderOptions

    func run() async throws {
      let environment = ProcessInfo.processInfo.environment
      let bootstrap = try AuthCommand.resolveBootstrapOrExit(environment: environment)
      try AuthCommand.finish(
        AuthCommand.workflow(
          bootstrap: bootstrap,
          environment: environment,
          executor: OfflineHTTPExecutor()
        ).status()
      )
    }
  }

  struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Remove the stored credential from this machine."
    )

    @OptionGroup var options: AuthProviderOptions

    func run() async throws {
      let environment = ProcessInfo.processInfo.environment
      let bootstrap = try AuthCommand.resolveBootstrapOrExit(environment: environment)
      try AuthCommand.finish(
        AuthCommand.workflow(
          bootstrap: bootstrap,
          environment: environment,
          executor: OfflineHTTPExecutor()
        ).logout()
      )
    }
  }
}

// MARK: - Composition

private extension AuthCommand {
  /// Hands the workflow the real lock, the real seal, the real store, and the owner's real terminal.
  ///
  /// The provider is not a parameter because there is one route that authenticates this way, and its
  /// identity is the workflow's own. When a second one arrives, this is where the option a caller
  /// parsed starts choosing between them.
  static func workflow(
    bootstrap: AuthBootstrap,
    environment: [String: String],
    executor: any HTTPExecuting
  ) -> AuthWorkflow {
    let stateRoot = bootstrap.stateRoot
    let oauth = ChatGPTOAuthClient(http: executor, wallDate: { Date() })

    return AuthWorkflow(
      bootstrap: bootstrap,
      runtimeSecrets: EnvironmentRuntimeSecrets(stateRoot: stateRoot, environment: environment),
      mutationLock: InstanceLockAdapter(
        path: SecretStatePaths(stateRoot: stateRoot).instanceLock.path
      ),
      makeCredentialStore: {
        EncryptedLLMCredentialStore(stateRoot: stateRoot)
      },
      makeDeviceAuthorization: {
        ChatGPTDeviceAuthorization(client: oauth, clock: ContinuousClock())
      },
      tokenExchange: oauth,
      catalog: ChatGPTModelCatalog(http: executor),
      terminal: StandardAuthTerminal(),
      profileID: { UUID() },
      wallDate: { Date() }
    )
  }

  /// Resolves the state root and the raw model reference, and nothing else. Deliberately not
  /// `AppConfig`: an owner diagnosing their credentials most needs an answer on the installation
  /// whose other configuration the daemon would refuse to boot on.
  static func resolveBootstrapOrExit(environment: [String: String]) throws -> AuthBootstrap {
    do {
      return try AuthBootstrap.resolve(environment: environment)
    } catch let error as ConfigError {
      FileHandle.standardError.write(Data("auth: config error: \(error)\n".utf8))
      throw ExitCode(error.exitCode)
    }
  }
}

// MARK: - Rendering

private extension AuthCommand {
  /// Presents what the command has left to say and ends with the code it decided on.
  ///
  /// Every event is printed for every command, with nothing asked about which one produced it: the
  /// result carries only what has not been shown yet, so login — which streams as it goes, because a
  /// device code arriving after the poll loop would be a code for a closed window — hands over
  /// nothing here and is not a special case.
  static func finish(_ result: AuthCommandResult) throws {
    for event in result.events {
      write(event)
    }

    let code = result.exit.processExitCode
    guard code == ExitCode.success.rawValue else {
      throw ExitCode(code)
    }
  }

  /// Honors the destination rather than printing everything to stdout: an owner piping
  /// `auth status` into a script must get the report and the complaints on different streams.
  static func write(_ event: AuthPresentationEvent) {
    let line = Data("\(event.text)\n".utf8)
    switch event.destination {
    case .standardOutput:
      FileHandle.standardOutput.write(line)
    case .standardError:
      FileHandle.standardError.write(line)
    }
  }
}

// MARK: - Seam Adapters

/// The daemon's own single-instance `flock`, as the lock the workflow asks for.
///
/// This file is the only one that knows both halves: the workflow must not learn that a lock is a
/// file, and the daemon's lock must not learn that anything but the daemon takes it.
private struct InstanceLockAdapter: AuthMutationLocking {
  let path: String

  func acquire() throws -> AuthMutationLease {
    let lock: InstanceLock
    do {
      lock = try InstanceLock(path: path)
    } catch InstanceLock.LockError.alreadyLocked {
      throw AuthMutationLockFailure.held
    } catch {
      throw AuthMutationLockFailure.unavailable(detail: "\(error)")
    }

    return AuthMutationLease {
      lock.release()
    }
  }
}

/// The real seal-and-prove-it, behind the workflow's one-call seam. The secrets it returns are the
/// ones the daemon will boot with; login wants only the proof that it can, so they are dropped here.
private struct EnvironmentRuntimeSecrets: AuthRuntimeSecretPreparing {
  let stateRoot: URL
  let environment: [String: String]

  func prepare() throws {
    _ = try RuntimeSecretPreparer.prepare(stateRoot: stateRoot, environment: environment)
  }
}

/// The executor status and logout are composed with.
///
/// They need one because the workflow is a single type whose login seams must be given something,
/// and they must not have a real one: neither command has a wire step, and reporting or deleting
/// what is on this disk is not a thing to open a socket for. So no client is built for them at all,
/// and this stands where one would have gone — failing closed if a wire step is ever added to a
/// command that promises it has none, rather than quietly reaching for the network.
private struct OfflineHTTPExecutor: HTTPExecuting {
  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    throw HTTPTransportFailure(
      disposition: .definitelyNotSent,
      safeMessage: "this command does not contact the provider"
    )
  }
}

// MARK: - Terminal

/// The owner's real terminal.
private struct StandardAuthTerminal: AuthTerminal {
  let isInteractive: Bool

  /// Both ends are asked about, because a prompt is worth printing only if the owner is there to
  /// read it and worth waiting on only if they are there to answer it.
  init() {
    isInteractive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
  }

  /// Read off the cooperative pool: `readLine` parks its thread until the owner types, and those
  /// threads are counted in cores. Blocking one to wait on a human is how a small host runs out.
  func readLine() async -> String? {
    await withCheckedContinuation { continuation in
      Self.input.async {
        continuation.resume(returning: Swift.readLine(strippingNewline: true))
      }
    }
  }

  func write(_ event: AuthPresentationEvent) async {
    AuthCommand.write(event)
  }
}

private extension StandardAuthTerminal {
  static let input = DispatchQueue(label: "clawd.auth.stdin")
}
