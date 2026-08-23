import ClawCore
import ClawProcess
import Foundation

/// Runs one shell command on the owner's own machine, outside the sandbox. Every call starts a
/// fresh shell at the workspace root, so nothing survives a call except what it wrote to disk.
public struct BashTool: Tool {
  /// The registry name, exposed so the composition root can enable this tool's dangerous-tier
  /// backstop without repeating the literal.
  public static let toolName = "bash"

  /// Slack over the per-call ceiling, so the launcher's own deadline is what reports a timeout
  /// and the dispatcher's is only a backstop.
  static let dispatchGrace = Duration.seconds(20)

  static let hostWarning = "this command runs on the host machine, outside the sandbox"

  /// Every daemon secret arrives through a `CLAW_`-prefixed variable, so stripping the prefix is
  /// what keeps a command from reading the bot token or an API key out of its own environment.
  static let strippedEnvironmentPrefix = "CLAW_"

  let workspaceRoot: URL
  let config: BashConfig
  let runner: any LocalCommandRunning
  let redactor: SecretRedactor

  public init(
    workspaceRoot: URL,
    config: BashConfig,
    runner: any LocalCommandRunning,
    redactor: SecretRedactor
  ) {
    self.workspaceRoot = workspaceRoot
    self.config = config
    self.runner = runner
    self.redactor = redactor
  }

  public var definition: ToolDefinition {
    ToolDefinition(
      name: Self.toolName,
      description: """
        Run one shell command on the host machine, with its real toolchain and filesystem (owner \
        approval required). Each call is a fresh shell whose working directory is always the \
        workspace root: a `cd`, a variable, or a background job does not carry into the next \
        call, though files the command writes do.
        """,
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "command": .object([
            "type": .string("string"),
            "description": .string("The shell command line to run."),
          ]),
          "timeoutSeconds": .object([
            "type": .string("integer"),
            "description": .string("How long the command may run before it is killed."),
            "minimum": .integer(1),
            "maximum": .integer(config.maxTimeoutSeconds),
            "default": .integer(config.defaultTimeoutSeconds),
          ]),
        ]),
        "required": .array([.string("command")]),
      ]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .dangerous
    )
  }

  public var timeout: Duration {
    .seconds(config.maxTimeoutSeconds) + Self.dispatchGrace
  }

  public func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? {
    nil
  }

  public func prepareAction(arguments: JSONValue) async -> PreparedActionResolution? {
    guard let raw = DangerousToolSupport.decode(RawArguments.self, from: arguments) else {
      return .refused(
        reason: "bash needs command as a string and timeoutSeconds as a whole number of seconds."
      )
    }

    let command = raw.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard command.isEmpty == false else {
      return .refused(reason: "bash needs a command to run.")
    }

    let timeoutSeconds: Int
    switch resolveTimeout(raw.timeoutSeconds) {
    case .refused(let reason):
      return .refused(reason: reason)
    case .resolved(let resolved):
      timeoutSeconds = resolved
    }

    let recorded = RecordedArguments(command: command, timeoutSeconds: timeoutSeconds)
    guard let canonicalArgsJSON = DangerousToolSupport.canonicalJSON(recorded) else {
      return .refused(reason: "The prepared bash action could not be encoded safely.")
    }

    return .prepared(
      PreparedToolAction(
        canonicalTarget: canonicalActionTarget(),
        canonicalArgsJSON: canonicalArgsJSON,
        presentation: approvalPresentation(recorded: recorded),
        guardTexts: [command],
        // The host keeps its network, so any command can reach outward; the trifecta tier has to
        // assume it will.
        canExfiltrate: true
      )
    )
  }

  public func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
    guard let approvedTarget = canonicalTarget else {
      return errorPayload("bash was dispatched without its approved target.")
    }
    guard let recorded = DangerousToolSupport.decode(RecordedArguments.self, from: arguments) else {
      return errorPayload("The recorded bash action is unreadable; nothing ran.")
    }
    guard recorded.command.isEmpty == false else {
      return errorPayload("The recorded bash action carries no command; nothing ran.")
    }
    // The shell and the working directory are what the owner approved; a config change between
    // approval and resume must not silently move the command onto a different one.
    guard canonicalActionTarget() == approvedTarget else {
      return errorPayload(
        "The recorded bash action no longer matches its approved target; nothing ran."
      )
    }

    let timeoutSeconds: Int
    switch resolveTimeout(recorded.timeoutSeconds) {
    case .refused:
      return errorPayload("The recorded bash timeout is no longer within its bound; nothing ran.")
    case .resolved(let resolved):
      timeoutSeconds = resolved
    }

    let result = await runner.run(
      LocalCommand(
        arguments: ["-c", recorded.command],
        timeout: .seconds(timeoutSeconds),
        captureLimit: LocalCommandLimits.maxRawStreamBytes,
        teardownGracePeriod: LocalCommandLimits.teardownGracePeriod,
        workingDirectory: workspaceRoot.path,
        environment: .inherit(removingPrefixes: [Self.strippedEnvironmentPrefix])
      )
    )

    return map(result: result, timeoutSeconds: timeoutSeconds)
  }
}

// MARK: - Argument Values

private extension BashTool {
  struct RawArguments: Decodable {
    let command: String
    let timeoutSeconds: Int?

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      command = try container.decode(String.self, forKey: .command)
      timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
    }

    private enum CodingKeys: String, CodingKey {
      case command
      case timeoutSeconds
    }
  }

  struct RecordedArguments: Codable, Equatable {
    let command: String
    let timeoutSeconds: Int
  }

  enum TimeoutResolution {
    case resolved(Int)
    case refused(String)
  }

  /// The model names the timeout it wants; the owner's ceiling is what it gets.
  func resolveTimeout(_ requested: Int?) -> TimeoutResolution {
    guard let requested else {
      return .resolved(min(config.defaultTimeoutSeconds, config.maxTimeoutSeconds))
    }
    guard requested > 0 else {
      return .refused("bash needs a timeout of at least one second.")
    }
    return .resolved(min(requested, config.maxTimeoutSeconds))
  }
}

// MARK: - Canonical Action

private extension BashTool {
  /// Every bash call acts on the same thing — one shell, one working directory — so the target
  /// pins that pair and the args hash alone distinguishes one command from the next.
  func canonicalActionTarget() -> String {
    "host_exec:\(config.shellPath):\(workspaceRoot.path)"
  }

  func approvalPresentation(recorded: RecordedArguments) -> ToolApprovalPresentation {
    ToolApprovalPresentation(
      blastRadius:
        "run \(config.shellPath) -c · cwd: \(workspaceRoot.path) · timeout \(recorded.timeoutSeconds)s",
      contentPreview: """
        ```bash
        \(redactor.redact(recorded.command))
        ```
        """,
      warnings: [Self.hostWarning]
    )
  }
}

// MARK: - Result Mapping

private extension BashTool {
  func map(result: LocalCommandResult, timeoutSeconds: Int) -> ToolPayload {
    switch result.termination {
    case .exited(let code):
      return outcomePayload(result, statusLine: DangerousToolSupport.exitStatusLine(code))
    case .signaled(let signal):
      return outcomePayload(result, statusLine: "killed by signal \(signal)")
    case .timedOut:
      return outcomePayload(
        result,
        statusLine: "timed out after \(timeoutSeconds)s",
        notes: ["The command was killed at its timeout; anything above is partial output."],
        status: .error
      )
    case .cancelled:
      return errorPayload("The bash command was cancelled before it finished.")
    case .startFailed(let reason):
      return errorPayload("bash could not start \(config.shellPath): \(reason)")
    }
  }

  func outcomePayload(
    _ result: LocalCommandResult,
    statusLine: String,
    notes: [String] = [],
    status: ToolObservationStatus = .ok
  ) -> ToolPayload {
    DangerousToolSupport.outcomePayload(
      DangerousToolSupport.CommandOutcome(
        statusLine: statusLine,
        stdout: Self.text(result.stdout),
        stderr: Self.text(result.stderr),
        notes: notes,
        truncatedRawStreams: result.stdout.truncated || result.stderr.truncated,
        status: status
      ),
      redactor: redactor
    )
  }

  // Lossy on purpose: a command is free to emit bytes that are not UTF-8, and dropping the whole
  // stream over one of them would hide the output the model was asked to read.
  static func text(_ stream: CapturedCommandStream) -> String {
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: stream.bytes, as: UTF8.self)
  }

  func errorPayload(_ reason: String) -> ToolPayload {
    DangerousToolSupport.errorPayload(reason, redactor: redactor)
  }
}
