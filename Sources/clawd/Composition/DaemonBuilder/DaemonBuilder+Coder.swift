import ClawCoder
import ClawCore
import ClawGateway
import ClawTools
import Foundation

struct CoderComposition: Sendable {
  let service: CoderService?
  let tools: [any Tool]
  let checks: [DoctorReport.Check]
}

struct CoderBackendSetup: Sendable {
  let backend: any CoderBackend
  let executable: String
  let profile: String?
  let configHome: String?
  let credentialSources: [String: String]
  let version: String
  let authentication: CodexAuthenticationStatus
  var searchPath: String?
  var githubExecutable: String?
  var nodeExecutable: String?

  var permitsSubmission: Bool {
    authentication == .authenticated || authentication == .profileUnverified
  }

  static func live(_ config: CoderConfig) async throws -> Self {
    try await inspect(config, environment: ProcessInfo.processInfo.environment)
  }

  static func inspect(_ config: CoderConfig, environment: [String: String]) async throws -> Self {
    let backend = try CodexBackend(config: config, environment: environment)
    let version = try await backend.compatibility()
    return Self(
      backend: backend,
      executable: backend.executable,
      profile: backend.profile,
      configHome: backend.configHome,
      credentialSources: backend.credentialSources,
      version: version,
      authentication: await backend.authenticationStatus(),
      searchPath: backend.searchPath,
      githubExecutable: backend.githubExecutable,
      nodeExecutable: backend.nodeExecutable
    )
  }
}

extension DaemonBuilder {
  func prepareCoder(coordination: TurnCoordination) async -> CoderComposition {
    guard config.coder.enabled else {
      let reservedJobs = try? stores.coderJobs.reservedJobs()
      let service =
        reservedJobs?.isEmpty == true
        ? nil
        : makeCoderService(
          backend: nil,
          policyID: Self.unavailableCoderPolicyID,
          coordination: coordination
        )
      return CoderComposition(service: service, tools: [], checks: CoderHealthRows.disabled)
    }

    do {
      let setup = try await resolveCoder(config.coder)
      return composeCoder(setup: setup, coordination: coordination)
    } catch {
      return unavailableCoder(error: error, coordination: coordination)
    }
  }

  func prepareConferenceCoder(
    coordination: TurnCoordination,
    environment: [String: String]
  ) async throws -> CoderComposition {
    guard config.coder.enabled else {
      throw ConferenceConfigError.coderRequired
    }

    let isolated = try conferenceCoderEnvironment(environment: environment)
    let setup = try await resolveConferenceCoder(config.coder, isolated)
    guard setup.permitsSubmission else {
      throw ConferenceConfigError.coderRequired
    }
    return composeCoder(
      setup: setup,
      coordination: coordination,
      completionNoticesEnabled: false
    )
  }

  func conferenceCoderEnvironment(environment: [String: String]) throws -> [String: String] {
    guard let configHome = config.coder.configHome,
      isDescendant(configHome, of: config.stateRoot.path)
    else {
      throw ConferenceConfigError.isolatedCoderHomeRequired
    }

    let home = config.stateRoot.appendingPathComponent("conference-home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    var isolated = environment
    isolated["HOME"] = home.path
    isolated["CODEX_HOME"] = configHome
    isolated.removeValue(forKey: "GH_TOKEN")
    isolated.removeValue(forKey: "GITHUB_TOKEN")
    isolated.removeValue(forKey: "GH_CONFIG_DIR")
    isolated.removeValue(forKey: "SSH_AUTH_SOCK")
    isolated.removeValue(forKey: "GIT_ASKPASS")
    return isolated
  }
}

// MARK: - Composition

private extension DaemonBuilder {
  func composeCoder(
    setup: CoderBackendSetup,
    coordination: TurnCoordination,
    completionNoticesEnabled: Bool = true
  ) -> CoderComposition {
    let checks = CoderHealthRows.rows(config: config.coder, setup: setup)
    let policy = CoderExecutionPolicy(
      executable: setup.executable,
      profile: setup.profile,
      configHome: setup.configHome,
      approvalPolicy: CodexBackend.approvalPolicy,
      credentialSources: setup.credentialSources,
      searchPath: setup.searchPath
    )

    let service = makeCoderService(
      backend: setup.permitsSubmission ? setup.backend : nil,
      policyID: policy.id,
      coordination: coordination,
      completionNoticesEnabled: completionNoticesEnabled
    )

    let redactor = SecretRedactor(secretValues: redactionValues)
    var tools: [any Tool] = [
      CoderStatusTool(service: service, redactor: redactor),
      CoderCancelTool(service: service, redactor: redactor),
    ]

    if setup.permitsSubmission {
      tools.insert(
        CoderSubmitTool(service: service, executionPolicyID: policy.id, redactor: redactor),
        at: 0
      )
    }

    return CoderComposition(service: service, tools: tools, checks: checks)
  }

  func unavailableCoder(
    error: any Error,
    coordination: TurnCoordination
  ) -> CoderComposition {
    let service = makeCoderService(
      backend: nil,
      policyID: Self.unavailableCoderPolicyID,
      coordination: coordination
    )
    let redactor = SecretRedactor(secretValues: redactionValues)

    return CoderComposition(
      service: service,
      tools: [
        CoderStatusTool(service: service, redactor: redactor),
        CoderCancelTool(service: service, redactor: redactor),
      ],
      checks: CoderHealthRows.unavailable(config: config.coder, error: error)
    )
  }

  func isDescendant(_ childPath: String, of rootPath: String) -> Bool {
    let child = URL(fileURLWithPath: childPath).standardizedFileURL.path
    let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    return child == root || child.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }
}

// MARK: - Service Ownership

private extension DaemonBuilder {
  static let unavailableCoderPolicyID = "coder-unavailable-no-execution-authority"

  func makeCoderService(
    backend: (any CoderBackend)?,
    policyID: String,
    coordination: TurnCoordination,
    completionNoticesEnabled: Bool = true
  ) -> CoderService {
    let redactor = SecretRedactor(secretValues: redactionValues)
    return CoderService(
      store: stores.coderJobs,
      backend: backend,
      preparer: CoderRequestPreparer(executionPolicyID: policyID),
      inspector: CoderProcessInspector(),
      config: config.coder,
      jobRoot: config.stateRoot.appendingPathComponent("coder/jobs").path,
      executionPolicyID: policyID,
      completionNoticesEnabled: completionNoticesEnabled,
      redact: {
        redactor.redact($0)
      },
      notifyOutbox: {
        coordination.outboxSignal.poke()
      }
    )
  }
}
