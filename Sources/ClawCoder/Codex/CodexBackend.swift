import ClawCore
import Foundation

public enum CodexAuthenticationStatus: Sendable, Equatable {
  case authenticated, missing, unavailable, profileUnverified
}

public struct CodexBackend: CoderBackend {
  public static let approvalPolicy = CodexInvocation.approvalPolicy

  public let executable: String
  public let profile: String?
  public let configHome: String?
  public let credentialSources: [String: String]
  public let searchPath: String
  public let githubExecutable: String?
  public let nodeExecutable: String?
  private let environment: [String: String]
  private let redactor: SecretRedactor

  public init(
    config: CoderConfig,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    var child = environment.filter {
      CodexInvocation.environmentKeys.contains($0.key)
    }
    child["HOME"] = child["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    searchPath = Self.effectivePath(config: config, environment: environment)
    child["PATH"] = searchPath

    if let home = config.configHome {
      child["CODEX_HOME"] = home
    }
    self.environment = child

    executable = try CodexInvocation.resolve(config.executable, environment: child)
    githubExecutable = try? CodexInvocation.resolve("gh", environment: child)
    nodeExecutable = try? CodexInvocation.resolve("node", environment: child)
    profile = config.profile
    configHome =
      child["CODEX_HOME"]
      ?? child["HOME"].map {
        URL(fileURLWithPath: $0).appendingPathComponent(".codex").path
      }

    var sources = child.filter {
      ["GH_CONFIG_DIR", "GH_HOST", "SSH_AUTH_SOCK"].contains($0.key)
    }
    sources["CODEX_HOME"] = configHome
    sources["GH_CONFIG_DIR"] =
      sources["GH_CONFIG_DIR"]
      ?? child["HOME"].map {
        URL(fileURLWithPath: $0).appendingPathComponent(".config/gh").path
      }
    sources["GH_HOST"] = sources["GH_HOST"] ?? "github.com"

    for key in CodexInvocation.credentialKeys where child[key] != nil {
      sources[key] = key
    }
    credentialSources = sources

    let secretValues = CodexInvocation.credentialKeys.compactMap {
      child[$0]
    }
    redactor = SecretRedactor(secretValues: secretValues)
  }

  public static func effectivePath(
    config: CoderConfig,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    config.searchPath ?? environment["PATH"] ?? "/usr/bin:/bin"
  }

  /// Checks fixed local CLI capabilities without inference or reading its authentication cache.
  public func compatibility() async throws -> String {
    let context = CodexCommandContext(
      environment: environment,
      directory: "/",
      tracking: .preApprovalReadOnly,
      phase: .prepare,
      deadline: ContinuousClock.now.advanced(by: CoderCommandRunner.readOnlyTimeout)
    )
    do {
      return redactor.redact(try await context.compatibility(executable: executable))
    } catch let error as CoderError {
      throw error
    } catch {
      throw CoderError.unavailable(
        """
        Codex CLI could not complete its compatibility checks. \
        Check its interpreter (npm installations need node in PATH), then run clawd coder setup.
        """
      )
    }
  }

  /// Local status never refreshes credentials or proves model entitlement; profiles are CLI-unobservable.
  public func authenticationStatus() async -> CodexAuthenticationStatus {
    if profile != nil {
      return .profileUnverified
    }
    let command = CoderCommand(
      executable: executable,
      arguments: ["login", "status"],
      environment: environment,
      workingDirectory: "/",
      input: "",
      phase: .prepare,
      timeout: CoderCommandRunner.readOnlyTimeout
    )
    let result = await CoderCommandRunner().run(command, tracking: .preApprovalReadOnly) { _ in }
    guard !result.supervisionFailed, result.cleanupResolved, !result.cancelled,
      !result.timedOut, result.signal == nil
    else {
      return .unavailable
    }
    switch result.exitCode {
    case 0: return .authenticated
    case 1:
      return result.diagnostics.trimmingCharacters(in: .whitespacesAndNewlines) == "Not logged in"
        ? .missing : .unavailable
    default: return .unavailable
    }
  }

  public func run(
    _ invocation: CoderInvocation,
    recordProcess: @Sendable (CoderProcessEvent) async throws -> Void
  ) async -> CoderResult {
    await run(invocation, workerRunner: CoderCommandRunner(), recordProcess: recordProcess)
  }

  func run(
    _ invocation: CoderInvocation,
    workerRunner: CoderCommandRunner,
    recordProcess: @Sendable (CoderProcessEvent) async throws -> Void
  ) async -> CoderResult {
    await withoutActuallyEscaping(recordProcess) { recordProcess in
      await execute(invocation, workerRunner: workerRunner, recordProcess: recordProcess)
    }
  }
}

// MARK: - Invocation lifetime

private extension CodexBackend {
  func execute(
    _ invocation: CoderInvocation,
    workerRunner: CoderCommandRunner,
    recordProcess: @Sendable @escaping (CoderProcessEvent) async throws -> Void
  ) async -> CoderResult {
    let deadline = ContinuousClock.now.advanced(by: invocation.timeout)
    var outcome = CodexOutcome()
    let protocolDirectory = URL(fileURLWithPath: invocation.jobDirectory)
      .appendingPathComponent("protocol-\(UUID().uuidString)")
    var stage = CoderFailureStage.preparation
    do {
      try PrivateDirectory.ensure(at: protocolDirectory)
      let prepare = CodexCommandContext(
        environment: environment,
        directory: invocation.jobDirectory,
        tracking: .job(record: recordProcess),
        phase: .prepare,
        deadline: deadline
      )
      stage = .launch
      _ = try await prepare.compatibility(executable: executable)
      stage = .preparation
      let workspace = try await CoderWorkspace().prepare(
        invocation,
        deadline: deadline,
        recordProcess: recordProcess
      )
      outcome.workspace = workspace
      outcome.localStartObserved = invocation.prepared.checkoutPath != nil
      let wire = try CodexInvocation(
        job: invocation,
        workspace: workspace,
        directory: protocolDirectory,
        profile: profile
      )
      let context = CodexCommandContext(
        environment: environment,
        directory: workspace.directory,
        tracking: .job(record: recordProcess),
        phase: .codex,
        deadline: deadline
      )
      stage = .launch
      await runWorker(
        wire,
        invocation: invocation,
        context: context,
        runner: workerRunner,
        outcome: &outcome
      )
    } catch {
      outcome.retainWorkspaceIfPresent(invocation)
      outcome.fail(stage, diagnostic(error))
      outcome.stopIfNeeded(deadline: deadline)
    }
    if FileManager.default.fileExists(atPath: protocolDirectory.path) {
      do { try FileManager.default.removeItem(at: protocolDirectory) } catch {
        outcome.fail(.cleanup, "Private Codex protocol files could not be removed.")
      }
    }
    return outcome.result(redactor: redactor)
  }

  func runWorker(
    _ wire: CodexInvocation,
    invocation: CoderInvocation,
    context: CodexCommandContext,
    runner: CoderCommandRunner,
    outcome: inout CodexOutcome
  ) async {
    do {
      let command = try context.command(
        executable: executable,
        arguments: wire.arguments,
        input: wire.input
      )
      if invocation.prepared.request.deliverable == .pullRequest {
        outcome.publication = .unknown(reportedURL: nil)
      }
      let events = CodexEvents()
      let process = await runner.run(command, tracking: context.tracking) { bytes in
        try await events.consume(bytes)
      }
      try? await events.finish()
      outcome.report = try? CodexReport.decode(at: wire.reportPath)
      outcome.usage = await events.usage
      if invocation.prepared.request.deliverable == .pullRequest || outcome.report?.prURL != nil {
        outcome.publication = .unknown(reportedURL: outcome.report?.prURL)
      }
      await classify(process: process, events: events, outcome: &outcome)
      outcome.stopIfNeeded(deadline: context.deadline)
      if outcome.state != .cancelled && outcome.state != .timedOut && process.cleanupResolved {
        let inspection = CodexCommandContext(
          environment: environment,
          directory: context.directory,
          tracking: context.tracking,
          phase: .inspect,
          deadline: context.deadline
        )
        do {
          try await CodexInspection(context: inspection).inspect(&outcome, invocation: invocation)
        } catch {
          if outcome.failure == nil {
            outcome.fail(
              .inspection,
              "Artifact inspection could not confirm the requested outcome."
            )
          }
          outcome.stopIfNeeded(deadline: context.deadline)
        }
      }
    } catch {
      outcome.fail(.launch, diagnostic(error))
      outcome.stopIfNeeded(deadline: context.deadline)
    }
  }

  func classify(
    process: CoderCommandResult,
    events: CodexEvents,
    outcome: inout CodexOutcome
  ) async {
    if process.cancelled {
      outcome.state = .cancelled
    } else if process.timedOut {
      outcome.state = .timedOut
    }
    if await events.invalid {
      outcome.fail(.protocolOutput, "Codex emitted invalid or oversized JSONL output.")
    } else if !process.cleanupResolved {
      outcome.fail(.cleanup, "Codex process ownership remains unresolved. \(process.diagnostics)")
    } else if process.supervisionFailed {
      outcome.fail(.execution, "Codex supervision failed. \(process.diagnostics)")
    } else if process.cancelled || process.timedOut {
      return
    } else if process.exitCode != 0 || process.signal != nil {
      outcome.fail(.execution, "Codex exited unsuccessfully. \(process.diagnostics)")
    } else if await events.failed {
      outcome.fail(.execution, "Codex reported a failed turn.")
    } else {
      await classifyReport(events: events, outcome: &outcome)
    }
  }

  func classifyReport(events: CodexEvents, outcome: inout CodexOutcome) async {
    if let report = outcome.report {
      switch report.status {
      case .blocked: outcome.fail(.permission, report.error ?? "Codex reported the task blocked.")
      case .failed: outcome.fail(.execution, report.error ?? "Codex reported the task failed.")
      case .succeeded:
        if await events.completed {
          outcome.state = .succeeded
        } else {
          outcome.fail(.protocolOutput, "Codex omitted terminal completion evidence.")
        }
      }
    } else {
      outcome.fail(.protocolOutput, "Codex final report is missing, invalid, unsafe or oversized.")
    }
  }

  func diagnostic(_ error: any Error) -> String {
    if case CoderError.unavailable(let message) = error {
      return message
    }
    if case CoderError.staleApproval = error {
      return "Coder workspace identity changed after approval."
    }
    return "Coder preparation or launch failed; retained workspace may contain partial work."
  }
}
