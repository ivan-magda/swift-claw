import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawTools

/// Group mode has no approval keyboard, so allowed calls must reach `execute` and hard refusals
/// must stop before it. The suite asserts observable effects at the dispatcher seam.
@Suite struct GroupModeToolPolicyTests {
  private static let memoryText = "The owner's private project is called Operation Nightjar Falcon."

  // MARK: - Fixtures

  private func makeWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "claw-group-gate-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeGate() -> ToolPolicyGate {
    ToolPolicyGate(
      argGuard: ExfilArgGuard(secretValues: ["s3cret-value-1"]),
      privateFileLoader: { [Self.memoryText] },
      enabledDangerousTools: [ExecuteCodeTool.toolName]
    )
  }

  private func makeDispatcher(tools: [any Tool]) -> GatedToolDispatcher {
    GatedToolDispatcher(
      registry: ToolRegistry(tools: tools),
      gate: makeGate()
    )
  }

  private func context(
    mode: ChatMode,
    trifectaHeld: Bool = false
  ) -> ToolDispatchContext {
    ToolDispatchContext(
      runId: 1,
      chatId: 42,
      sessionTainted: trifectaHeld,
      runIngestedUntrusted: false,
      assemblyPrivateData: trifectaHeld,
      runPrivateData: false,
      sessionHasPrivateData: false,
      approvalAlreadyPending: false,
      runOrigin: .interactive,
      autoApproveWindowOpen: false,
      mode: mode
    )
  }

  private func writeCall(path: String, content: String = "hello from the topic") -> ToolCall {
    ToolCall(
      id: "call-write",
      name: "file_write",
      argumentsJSON: #"{"path":"\#(path)","content":"\#(content)"}"#
    )
  }

  private func execCall(code: String = "print('hello')") -> ToolCall {
    ToolCall(
      id: "call-exec",
      name: "execute_code",
      argumentsJSON: #"{"language":"python","code":"\#(code)","stage":[],"network":false}"#
    )
  }

  private func makeExecuteTool(
    workspaceRoot: URL,
    backend: FakeExecutionBackend
  ) -> ExecuteCodeTool {
    ExecuteCodeTool(
      workspaceRoot: workspaceRoot,
      backend: backend,
      settings: ExecuteCodeSettings(
        memoryMiB: 1024,
        cpus: 4,
        timeout: .seconds(30),
        allowEgress: false
      ),
      redactor: SecretRedactor(secretValues: [])
    )
  }

  // MARK: - Executed side effects

  @Test func groupModeFileWriteCreatesTheFile() async throws {
    // given
    let root = try makeWorkspace()
    let dispatcher = makeDispatcher(
      tools: [FileWriteTool(workspaceRoot: root, redactor: SecretRedactor(secretValues: []))]
    )

    // when
    let outcome = await dispatcher.dispatch(
      call: writeCall(path: "notes/plan.md"),
      context: context(mode: .group)
    )

    // then
    #expect(outcome.requiresApproval == nil)
    #expect(outcome.observation.status == .ok)
    let written = try String(
      contentsOf: root.appendingPathComponent("notes/plan.md"),
      encoding: .utf8
    )
    #expect(written == "hello from the topic")
  }

  @Test func groupModeExecuteCodeProducesProgramOutput() async throws {
    // given
    let root = try makeWorkspace()
    let backend = FakeExecutionBackend()
    await backend.enqueue(
      ExecutionResult(
        terminationReason: .exited(code: 0),
        stdout: "hello\n",
        stderr: "",
        truncatedRawBytes: false
      )
    )
    let dispatcher = makeDispatcher(tools: [makeExecuteTool(workspaceRoot: root, backend: backend)])

    // when
    let outcome = await dispatcher.dispatch(call: execCall(), context: context(mode: .group))

    // then
    #expect(outcome.requiresApproval == nil)
    #expect(outcome.observation.status == .ok)
    #expect(outcome.observation.content.contains("hello"))
    #expect(outcome.observation.content.contains("unreadable") == false)
  }

  @Test func groupModeFetchUnderTrifectaReturnsContent() async {
    // given — a would-be-trifecta call: tainted session plus private assembly data.
    let dispatcher = makeDispatcher(tools: [FetchLikeTool()])
    let call = ToolCall(
      id: "call-fetch",
      name: "web_fetch",
      argumentsJSON: #"{"url":"https://example.com/notes"}"#
    )

    // when
    let outcome = await dispatcher.dispatch(
      call: call,
      context: context(mode: .group, trifectaHeld: true)
    )

    // then
    #expect(outcome.requiresApproval == nil)
    #expect(outcome.observation.status == .ok)
    #expect(outcome.observation.content == "fetched")
  }

  // MARK: - Group-mode refusals

  @Test func groupModeRefusesMemoryWrite() async {
    // given
    let dispatcher = makeDispatcher(tools: [
      MemoryWriteTool(redactor: SecretRedactor(secretValues: []))
    ])
    let call = ToolCall(
      id: "call-memory",
      name: "memory_write",
      argumentsJSON: #"{"text":"the crew met on Monday","kind":"project"}"#
    )

    // when
    let outcome = await dispatcher.dispatch(call: call, context: context(mode: .group))

    // then — refused by the gate, never reaching the tool's approval-only stub
    #expect(outcome.requiresApproval == nil)
    #expect(outcome.observation.status == .error)
    #expect(outcome.observation.content.contains("approval resume path") == false)
  }

  @Test func groupModeRefusesPrivilegedPromptFileWrite() async throws {
    // given — filename enumeration belongs to WorkspaceValuesTests
    let root = try makeWorkspace()
    let name = WorkspaceFile.soul.relativePath
    let dispatcher = makeDispatcher(
      tools: [FileWriteTool(workspaceRoot: root, redactor: SecretRedactor(secretValues: []))]
    )

    // when
    let outcome = await dispatcher.dispatch(
      call: writeCall(path: name),
      context: context(mode: .group)
    )

    // then
    #expect(outcome.observation.status == .error)
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) == false
    )
  }
}
