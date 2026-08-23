import ClawCore
import ClawProcess
import ClawTestSupport
import Foundation
import Testing

@testable import ClawTools

@Suite struct BashToolTests {
  private struct PreparationFailure: Error {}

  private func makeTool(
    root: String = "/tmp/claw-bash-workspace",
    shellPath: String = "/bin/zsh",
    defaultTimeoutSeconds: Int = 30,
    maxTimeoutSeconds: Int = 300,
    secrets: [String] = [],
    runner: any LocalCommandRunning = NoopCommandRunner()
  ) -> BashTool {
    BashTool(
      workspaceRoot: URL(fileURLWithPath: root, isDirectory: true),
      config: BashConfig(
        enabled: true,
        shellPath: shellPath,
        defaultTimeoutSeconds: defaultTimeoutSeconds,
        maxTimeoutSeconds: maxTimeoutSeconds
      ),
      runner: runner,
      redactor: SecretRedactor(secretValues: secrets)
    )
  }

  private func recordedInvocation(
    tool: BashTool,
    command: String,
    timeoutSeconds: Int? = nil
  ) async throws -> (JSONValue, String) {
    let action = try prepared(
      await tool.prepareAction(
        arguments: arguments(command: command, timeoutSeconds: timeoutSeconds)
      )
    )
    let recorded = try #require(JSONValue.parse(action.canonicalArgsJSON))
    return (recorded, action.canonicalTarget)
  }

  private func arguments(command: String, timeoutSeconds: Int? = nil) -> JSONValue {
    var fields: [String: JSONValue] = ["command": .string(command)]
    if let timeoutSeconds {
      fields["timeoutSeconds"] = .integer(timeoutSeconds)
    }
    return .object(fields)
  }

  private func prepared(_ resolution: PreparedActionResolution?) throws -> PreparedToolAction {
    guard case .prepared(let action) = resolution else {
      Issue.record("expected prepared action, got \(String(describing: resolution))")
      throw PreparationFailure()
    }
    return action
  }

  private func refusalReason(_ resolution: PreparedActionResolution?) throws -> String {
    guard case .refused(let reason) = resolution else {
      Issue.record("expected refusal, got \(String(describing: resolution))")
      throw PreparationFailure()
    }
    return reason
  }

  @Test func definitionDeclaresDangerousHostPosture() {
    // given
    let tool = makeTool()

    // when
    let definition = tool.definition

    // then
    #expect(definition.name == "bash")
    #expect(definition.riskLevel == .dangerous)
    #expect(definition.egressClass == .none)
    #expect(definition.metadataProvenance == .trusted)
    #expect(definition.fenceLabel == "bash")
  }

  @Test func definitionSchemaTakesCommandAndOptionalTimeout() {
    // given
    let tool = makeTool(defaultTimeoutSeconds: 45, maxTimeoutSeconds: 120)

    // when
    let schema = tool.definition.parameters.objectValue

    // then
    #expect(schema?["required"] == .array([.string("command")]))
    let properties = schema?["properties"]?.objectValue
    #expect(properties?["command"]?.objectValue?["type"] == .string("string"))
    let timeout = properties?["timeoutSeconds"]?.objectValue
    #expect(timeout?["type"] == .string("integer"))
    #expect(timeout?["minimum"] == .integer(1))
    #expect(timeout?["maximum"] == .integer(120))
    #expect(timeout?["default"] == .integer(45))
  }

  @Test func canonicalTargetIsUnresolvedForANonEgressTool() {
    // given
    let tool = makeTool()

    // when
    let resolution = tool.canonicalTarget(arguments: arguments(command: "ls"))

    // then
    #expect(resolution == nil)
  }

  @Test func preparedTargetNamesTheShellAndTheWorkspaceRoot() async throws {
    // given
    let tool = makeTool(root: "/tmp/claw-root", shellPath: "/bin/bash")

    // when
    let action = try prepared(await tool.prepareAction(arguments: arguments(command: "ls -la")))

    // then
    #expect(action.canonicalTarget.contains("/bin/bash"))
    #expect(action.canonicalTarget.contains("/tmp/claw-root"))
  }

  @Test func preparedActionCarriesTheCommandToTheArgumentGuard() async throws {
    // given
    let tool = makeTool()

    // when
    let action = try prepared(
      await tool.prepareAction(arguments: arguments(command: "cat secrets.txt"))
    )

    // then
    #expect(action.guardTexts == ["cat secrets.txt"])
  }

  @Test func preparedActionDeclaresItCanExfiltrate() async throws {
    // given
    let tool = makeTool()

    // when
    let action = try prepared(await tool.prepareAction(arguments: arguments(command: "ls")))

    // then
    #expect(action.canExfiltrate)
  }

  @Test func canonicalArgumentsAreSortedKeyJSON() async throws {
    // given
    let tool = makeTool(defaultTimeoutSeconds: 30)

    // when
    let action = try prepared(
      await tool.prepareAction(arguments: arguments(command: "echo hi", timeoutSeconds: 12))
    )

    // then
    #expect(action.canonicalArgsJSON == #"{"command":"echo hi","timeoutSeconds":12}"#)
  }

  @Test func omittedTimeoutTakesTheConfiguredDefault() async throws {
    // given
    let tool = makeTool(defaultTimeoutSeconds: 45, maxTimeoutSeconds: 300)

    // when
    let action = try prepared(await tool.prepareAction(arguments: arguments(command: "sleep 1")))

    // then
    #expect(action.canonicalArgsJSON.contains(#""timeoutSeconds":45"#))
  }

  @Test func oversizedTimeoutClampsToTheCeiling() async throws {
    // given
    let tool = makeTool(defaultTimeoutSeconds: 30, maxTimeoutSeconds: 120)

    // when
    let action = try prepared(
      await tool.prepareAction(arguments: arguments(command: "sleep 999", timeoutSeconds: 9999))
    )

    // then
    #expect(action.canonicalArgsJSON.contains(#""timeoutSeconds":120"#))
  }

  @Test(arguments: [0, -5])
  func nonPositiveTimeoutRefuses(requested: Int) async throws {
    // given
    let tool = makeTool()

    // when
    let reason = try refusalReason(
      await tool.prepareAction(arguments: arguments(command: "ls", timeoutSeconds: requested))
    )

    // then
    #expect(reason.contains("bash"))
    #expect(reason.contains("second"))
  }

  @Test func aMissingCommandRefuses() async throws {
    // given
    let tool = makeTool()

    // when
    let reason = try refusalReason(
      await tool.prepareAction(arguments: .object(["timeoutSeconds": .integer(10)]))
    )

    // then
    #expect(reason.contains("bash"))
  }

  @Test(arguments: ["", "   \n "])
  func anEmptyCommandRefuses(command: String) async throws {
    // given
    let tool = makeTool()

    // when
    let reason = try refusalReason(await tool.prepareAction(arguments: arguments(command: command)))

    // then
    #expect(reason.contains("bash"))
    #expect(reason.contains("command"))
  }

  @Test func aMistypedTimeoutRefuses() async throws {
    // given
    let tool = makeTool()

    // when
    let resolution = await tool.prepareAction(
      arguments: .object(["command": .string("ls"), "timeoutSeconds": .string("30")])
    )

    // then
    #expect(try refusalReason(resolution).contains("bash"))
  }

  @Test func theApprovalPreviewRedactsSecretsInTheCommand() async throws {
    // given
    let tool = makeTool(secrets: ["hunter2"])

    // when
    let action = try prepared(
      await tool.prepareAction(
        arguments: arguments(command: "curl -H 'token: hunter2' example.com")
      )
    )

    // then
    #expect(action.presentation.contentPreview?.contains("hunter2") == false)
    #expect(action.presentation.contentPreview?.contains(SecretRedactor.replacement) == true)
    // The canonical action keeps the true command — only the owner-facing preview is redacted.
    #expect(action.guardTexts == ["curl -H 'token: hunter2' example.com"])
  }

  @Test func theApprovalBlastRadiusStatesTheShellCwdAndTimeout() async throws {
    // given
    let tool = makeTool(root: "/tmp/claw-root", shellPath: "/bin/zsh")

    // when
    let action = try prepared(
      await tool.prepareAction(arguments: arguments(command: "ls", timeoutSeconds: 7))
    )

    // then
    let blastRadius = action.presentation.blastRadius
    #expect(blastRadius.contains("/bin/zsh"))
    #expect(blastRadius.contains("/tmp/claw-root"))
    #expect(blastRadius.contains("7s"))
  }

  @Test func theApprovalWarnsThatTheCommandRunsOnTheHost() async throws {
    // given
    let tool = makeTool()

    // when
    let action = try prepared(await tool.prepareAction(arguments: arguments(command: "ls")))

    // then
    #expect(action.presentation.warnings.contains { $0.contains("host") })
  }

  @Test func theDispatchTimeoutOutlastsTheConfiguredCeiling() {
    // given
    let tool = makeTool(maxTimeoutSeconds: 120)

    // when
    let timeout = tool.timeout

    // then
    #expect(timeout > .seconds(120))
  }
}

extension BashToolTests {
  @Test func aSuccessfulCommandReportsItsExitCodeAndBothStreams() async throws {
    // given
    let runner = ScriptedCommandRunner(
      result: commandResult(.exited(0), stdout: "listing", stderr: "warning")
    )
    let tool = makeTool(runner: runner)
    let (recorded, target) = try await recordedInvocation(tool: tool, command: "ls")

    // when
    let payload = await tool.execute(arguments: recorded, canonicalTarget: target)

    // then
    #expect(payload.status == .ok)
    #expect(payload.ingestedUntrusted)
    #expect(payload.readPrivateData == false)
    #expect(payload.content.contains("exit 0"))
    #expect(payload.content.contains("listing"))
    #expect(payload.content.contains("warning"))
  }

  @Test func theLaunchedCommandRunsTheShellAtTheWorkspaceRootWithoutClawVariables() async throws {
    // given
    let runner = ScriptedCommandRunner(result: commandResult(.exited(0)))
    let tool = makeTool(root: "/tmp/claw-root", runner: runner)
    let (recorded, target) = try await recordedInvocation(
      tool: tool,
      command: "env",
      timeoutSeconds: 12
    )

    // when
    _ = await tool.execute(arguments: recorded, canonicalTarget: target)

    // then
    let launched = try #require(await runner.recorded().first)
    #expect(launched.arguments == ["-c", "env"])
    #expect(launched.workingDirectory == "/tmp/claw-root")
    #expect(launched.timeout == .seconds(12))
    #expect(launched.environment.removes("CLAW_TELEGRAM_BOT_TOKEN"))
    #expect(launched.environment.removes("CLAW_LLM_API_KEY"))
    #expect(launched.environment.removes("PATH") == false)
  }

  @Test func aFailingCommandIsAnObservationNotAToolFault() async throws {
    // given
    let runner = ScriptedCommandRunner(
      result: commandResult(.exited(2), stdout: "", stderr: "no such file")
    )
    let tool = makeTool(runner: runner)
    let (recorded, target) = try await recordedInvocation(tool: tool, command: "cat missing")

    // when
    let payload = await tool.execute(arguments: recorded, canonicalTarget: target)

    // then
    #expect(payload.status == .ok)
    #expect(payload.content.contains("exit 2"))
    #expect(payload.content.contains("no such file"))
  }

  @Test func aTimeoutKeepsThePartialOutputAndStatesTheReason() async throws {
    // given
    let runner = ScriptedCommandRunner(
      result: commandResult(.timedOut, stdout: "first line", stderr: "")
    )
    let tool = makeTool(runner: runner)
    let (recorded, target) = try await recordedInvocation(
      tool: tool,
      command: "sleep 999",
      timeoutSeconds: 5
    )

    // when
    let payload = await tool.execute(arguments: recorded, canonicalTarget: target)

    // then
    #expect(payload.status == .error)
    #expect(payload.content.contains("timed out after 5s"))
    #expect(payload.content.contains("first line"))
    #expect(payload.content.contains("partial output"))
  }

  @Test func aMissingShellReportsOwnerFacingCopy() async throws {
    // given
    let runner = ScriptedCommandRunner(
      result: commandResult(.startFailed("executable not found"))
    )
    let tool = makeTool(shellPath: "/opt/nowhere/zsh", runner: runner)
    let (recorded, target) = try await recordedInvocation(tool: tool, command: "ls")

    // when
    let payload = await tool.execute(arguments: recorded, canonicalTarget: target)

    // then
    #expect(payload.status == .error)
    #expect(payload.content.contains("could not start"))
    #expect(payload.content.contains("/opt/nowhere/zsh"))
  }

  @Test func aCancelledCommandReportsOwnerFacingCopy() async throws {
    // given
    let runner = ScriptedCommandRunner(result: commandResult(.cancelled))
    let tool = makeTool(runner: runner)
    let (recorded, target) = try await recordedInvocation(tool: tool, command: "sleep 5")

    // when
    let payload = await tool.execute(arguments: recorded, canonicalTarget: target)

    // then
    #expect(payload.status == .error)
    #expect(payload.content.contains("cancelled"))
  }

  @Test func aTargetThatNoLongerMatchesTheApprovedShellRunsNothing() async throws {
    // given
    let runner = ScriptedCommandRunner(result: commandResult(.exited(0)))
    let approvingTool = makeTool(shellPath: "/bin/zsh", runner: runner)
    let (recorded, target) = try await recordedInvocation(tool: approvingTool, command: "ls")
    let executingTool = makeTool(shellPath: "/bin/bash", runner: runner)

    // when
    let payload = await executingTool.execute(arguments: recorded, canonicalTarget: target)

    // then
    #expect(payload.status == .error)
    #expect(payload.content.contains("no longer matches"))
    #expect(await runner.recorded().isEmpty)
  }

  @Test func rawStreamOverflowCarriesOneNoticeAndTheOutputCapAppliesOnce() async throws {
    // given
    let secret = String(repeating: "boundary-secret-value-", count: 20)
    let overflowing =
      String(repeating: "x", count: ToolOutputCap.maxGraphemes - 100) + secret
      + String(repeating: "y", count: 1_000)
    let runner = ScriptedCommandRunner(
      result: commandResult(
        .exited(0),
        stdout: Data(overflowing.utf8),
        stdoutTotal: overflowing.utf8.count + 1,
        stdoutTruncated: true
      )
    )
    let tool = makeTool(secrets: [secret], runner: runner)
    let (recorded, target) = try await recordedInvocation(tool: tool, command: "cat big.log")

    // when
    let payload = await tool.execute(arguments: recorded, canonicalTarget: target)

    // then
    #expect(payload.content.contains(secret) == false)
    #expect(payload.content.contains(SecretRedactor.replacement))
    #expect(
      payload.content.components(separatedBy: ToolOutputCap.truncationMarker).count - 1 == 1
    )
    #expect(payload.content.count <= ToolOutputCap.maxGraphemes)
  }

  @Test func theRawTruncationNoticeIsAddedOnlyWhenAStreamWasCut() async throws {
    // given
    let runner = ScriptedCommandRunner(
      result: commandResult(
        .exited(0),
        stdout: Data("short".utf8),
        stdoutTotal: 4_096,
        stdoutTruncated: true
      )
    )
    let tool = makeTool(runner: runner)
    let (recorded, target) = try await recordedInvocation(tool: tool, command: "cat big.log")

    // when
    let payload = await tool.execute(arguments: recorded, canonicalTarget: target)

    // then
    #expect(
      payload.content.components(separatedBy: DangerousToolSupport.rawOutputTruncationNotice)
        .count - 1 == 1
    )
    #expect(payload.content.contains(ToolOutputCap.truncationMarker) == false)
  }
}
