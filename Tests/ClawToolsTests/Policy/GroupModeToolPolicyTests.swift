import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawTools

/// Group mode has no approval keyboard, so the gate must reach `execute` on its own. Every test
/// here asserts the SIDE EFFECT — a file on disk, program output, fetched content — because a
/// verdict assertion alone passes while the execution path is still broken.
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

  private func makeGate(execEnabled: Bool = true) -> ToolPolicyGate {
    ToolPolicyGate(
      argGuard: ExfilArgGuard(secretValues: ["s3cret-value-1"]),
      privateFileLoader: { [Self.memoryText] },
      execEnabled: execEnabled
    )
  }

  private func makeDispatcher(tools: [any Tool], execEnabled: Bool = true) -> GatedToolDispatcher {
    GatedToolDispatcher(
      registry: ToolRegistry(tools: tools),
      gate: makeGate(execEnabled: execEnabled)
    )
  }

  private func context(
    mode: ChatMode,
    trifectaHeld: Bool = false
  ) -> ToolDispatchContext {
    ToolDispatchContext(
      sessionTainted: trifectaHeld,
      runIngestedUntrusted: false,
      assemblyPrivateData: trifectaHeld,
      runPrivateData: false,
      sessionHasPrivateData: false,
      approvalAlreadyPending: false,
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

  @Test(arguments: ["SOUL.md", "AGENTS.md", "USER.md", "MEMORY.md"])
  func groupModeRefusesPrivilegedPromptFileWrite(name: String) async throws {
    // given
    let root = try makeWorkspace()
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

  @Test func groupModeFileWriteOutsideWorkspaceStillFails() async throws {
    // given
    let root = try makeWorkspace()
    let dispatcher = makeDispatcher(
      tools: [FileWriteTool(workspaceRoot: root, redactor: SecretRedactor(secretValues: []))]
    )

    // when
    let outcome = await dispatcher.dispatch(
      call: writeCall(path: "../escaped.md"),
      context: context(mode: .group)
    )

    // then
    #expect(outcome.observation.status == .error)
    #expect(
      FileManager.default.fileExists(
        atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.md").path
      ) == false
    )
  }

  @Test(arguments: [ChatMode.direct, ChatMode.group])
  func executeCodeStillRefusesWhenExecutionIsDisabled(mode: ChatMode) async throws {
    // given
    let root = try makeWorkspace()
    let backend = FakeExecutionBackend()
    let dispatcher = makeDispatcher(
      tools: [makeExecuteTool(workspaceRoot: root, backend: backend)],
      execEnabled: false
    )

    // when
    let outcome = await dispatcher.dispatch(call: execCall(), context: context(mode: mode))

    // then
    #expect(outcome.requiresApproval == nil)
    #expect(outcome.observation.status == .error)
    #expect(outcome.observation.content == "Code execution is disabled.")
  }

  // MARK: - DM mode is unchanged

  @Test func directModeStillParksTheAskTier() async throws {
    // given
    let root = try makeWorkspace()
    let dispatcher = makeDispatcher(
      tools: [FileWriteTool(workspaceRoot: root, redactor: SecretRedactor(secretValues: []))]
    )

    // when
    let outcome = await dispatcher.dispatch(
      call: writeCall(path: "notes/plan.md"),
      context: context(mode: .direct)
    )

    // then
    #expect(outcome.requiresApproval?.reason == .askTier)
    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("notes/plan.md").path
      ) == false
    )
  }

  @Test func directModeStillArmsTheTrifecta() async {
    // given
    let dispatcher = makeDispatcher(tools: [FetchLikeTool()])
    let call = ToolCall(
      id: "call-fetch",
      name: "web_fetch",
      argumentsJSON: #"{"url":"https://example.com/notes"}"#
    )

    // when
    let outcome = await dispatcher.dispatch(
      call: call,
      context: context(mode: .direct, trifectaHeld: true)
    )

    // then
    #expect(outcome.requiresApproval?.reason == .exfilTrifecta)
    #expect(outcome.observation.status == .blockedPendingApproval)
  }

  @Test func directModeStillParksTheDangerousTier() async throws {
    // given
    let root = try makeWorkspace()
    let backend = FakeExecutionBackend()
    let dispatcher = makeDispatcher(tools: [makeExecuteTool(workspaceRoot: root, backend: backend)])

    // when
    let outcome = await dispatcher.dispatch(call: execCall(), context: context(mode: .direct))

    // then
    #expect(outcome.requiresApproval?.reason == .codeExec)
    #expect(outcome.observation.status == .blockedPendingApproval)
  }
}
