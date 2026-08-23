import ClawCore
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
    secrets: [String] = []
  ) -> BashTool {
    BashTool(
      workspaceRoot: URL(fileURLWithPath: root, isDirectory: true),
      config: BashConfig(
        enabled: true,
        shellPath: shellPath,
        defaultTimeoutSeconds: defaultTimeoutSeconds,
        maxTimeoutSeconds: maxTimeoutSeconds
      ),
      redactor: SecretRedactor(secretValues: secrets)
    )
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
