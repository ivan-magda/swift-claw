import ClawCore
import ClawProcess
import ClawTestSupport
import Foundation
import Testing

@testable import ClawTools

/// Both dangerous-tier tools report a finished command through one renderer; the model reads
/// their output the same way, so a divergence here is a change in what the model sees.
@Suite struct DangerousToolRenderingTests {
  private struct PreparationFailure: Error {}

  private func makeWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "claw-dangerous-rendering-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func prepared(_ resolution: PreparedActionResolution?) throws -> PreparedToolAction {
    guard case .prepared(let action) = resolution else {
      Issue.record("expected prepared action, got \(String(describing: resolution))")
      throw PreparationFailure()
    }
    return action
  }

  private func execute(_ tool: some Tool, action: PreparedToolAction) async throws -> ToolPayload {
    let recorded = try #require(JSONValue.parse(action.canonicalArgsJSON))
    return await tool.execute(arguments: recorded, canonicalTarget: action.canonicalTarget)
  }

  @Test func bothToolsRenderTheSameExitCodeAndStreamsIdentically() async throws {
    // given
    let root = try makeWorkspace()
    let sandboxTool = ExecuteCodeTool(
      workspaceRoot: root,
      backend: FakeExecutionBackend(
        results: [
          ExecutionResult(
            terminationReason: .exited(code: 3),
            stdout: "shared out",
            stderr: "shared err",
            truncatedRawBytes: true
          )
        ]
      ),
      settings: ExecuteCodeSettings(
        memoryMiB: 1024,
        cpus: 4,
        timeout: .seconds(30),
        allowEgress: false
      ),
      redactor: SecretRedactor(secretValues: [])
    )
    let hostTool = BashTool(
      workspaceRoot: root,
      config: BashConfig(
        enabled: true,
        shellPath: "/bin/zsh",
        defaultTimeoutSeconds: 30,
        maxTimeoutSeconds: 300
      ),
      runner: ScriptedCommandRunner(
        result: commandResult(
          .exited(3),
          stdout: Data("shared out".utf8),
          stderr: Data("shared err".utf8),
          stdoutTruncated: true
        )
      ),
      redactor: SecretRedactor(secretValues: [])
    )

    // when
    let sandboxPayload = try await execute(
      sandboxTool,
      action: prepared(
        await sandboxTool.prepareAction(
          arguments: .object([
            "language": .string("sh"),
            "code": .string("echo hi"),
          ])
        )
      )
    )
    let hostPayload = try await execute(
      hostTool,
      action: prepared(
        await hostTool.prepareAction(arguments: .object(["command": .string("echo hi")]))
      )
    )

    // then
    #expect(sandboxPayload.content == hostPayload.content)
    #expect(sandboxPayload.status == hostPayload.status)
    #expect(sandboxPayload.ingestedUntrusted == hostPayload.ingestedUntrusted)
    #expect(hostPayload.content.contains(DangerousToolSupport.rawOutputTruncationNotice))
  }
}
