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

  var permitsSubmission: Bool {
    authentication == .authenticated || authentication == .profileUnverified
  }

  static func live(_ config: CoderConfig) async throws -> Self {
    let backend = try CodexBackend(config: config)
    let version = try await backend.compatibility()
    return Self(
      backend: backend,
      executable: backend.executable,
      profile: backend.profile,
      configHome: backend.configHome,
      credentialSources: backend.credentialSources,
      version: version,
      authentication: await backend.authenticationStatus()
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
      let checks = CoderHealthRows.rows(config: config.coder, setup: setup)
      let policy = CoderExecutionPolicy(
        executable: setup.executable,
        profile: setup.profile,
        configHome: setup.configHome,
        approvalPolicy: CodexBackend.approvalPolicy,
        credentialSources: setup.credentialSources
      )
      let service = makeCoderService(
        backend: setup.permitsSubmission ? setup.backend : nil,
        policyID: policy.id,
        coordination: coordination
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
    } catch {
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
        checks: CoderHealthRows.unavailable(config: config.coder)
      )
    }
  }
}

// MARK: - Service Ownership

private extension DaemonBuilder {
  static let unavailableCoderPolicyID = "coder-unavailable-no-execution-authority"

  func makeCoderService(
    backend: (any CoderBackend)?,
    policyID: String,
    coordination: TurnCoordination
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
      redact: {
        redactor.redact($0)
      },
      notifyOutbox: {
        coordination.outboxSignal.poke()
      }
    )
  }
}
