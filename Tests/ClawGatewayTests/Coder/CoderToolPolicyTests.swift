import ClawCore
import ClawTestSupport
import ClawTools
import Foundation
import Testing

@testable import ClawGateway

@Suite struct CoderToolPolicyTests {
  enum MissingIdentity: CaseIterable { case context, requester, proactive, modeMismatch }
  enum OutboundScope: CaseIterable { case source, startRef, baseBranch }

  @Test(arguments: MissingIdentity.allCases)
  func requesterRequiredToolsRefuseInvalidIdentity(_ missing: MissingIdentity) async throws {
    // given
    let fixture = try CoderServiceFixture()
    try await fixture.withJoinedCleanup {
      let tool = CoderStatusTool(
        service: fixture.service,
        redactor: SecretRedactor(secretValues: [])
      )
      let execution: ToolExecutionContext? =
        missing == .context
        ? nil
        : ToolExecutionContext(
          runId: 1,
          sessionId: 1,
          chatId: 7,
          requesterUserId: missing == .requester ? nil : 7,
          origin: missing == .proactive ? .scheduled : .interactive,
          mode: missing == .modeMismatch ? .group : .direct,
          toolCallId: "status",
          approvalId: nil
        )

      // when
      let verdict = await gate().evaluate(
        call: ToolCall(id: "status", name: tool.definition.name, argumentsJSON: "{}"),
        tool: tool,
        context: context(execution, mode: .direct)
      )

      // then
      guard case .block(let payload, _) = verdict else {
        Issue.record("Requester-required tool passed invalid identity admission")
        return
      }
      #expect(payload.status == .error)
    }
  }

  @Test func coderEnabledDoesNotEnableVMExecution() async throws {
    // given
    let fixture = try CoderServiceFixture()
    try await fixture.withJoinedCleanup {
      try await fixture.service.start()
      let redactor = SecretRedactor(secretValues: [])
      let coder = CoderSubmitTool(
        service: fixture.service,
        executionPolicyID: CoderServiceFixture.executionPolicyID,
        redactor: redactor
      )
      let sandboxTool = ExecuteCodeTool(
        workspaceRoot: fixture.root,
        backend: FakeExecutionBackend(),
        settings: ExecuteCodeSettings(
          memoryMiB: 1024,
          cpus: 1,
          timeout: .seconds(30),
          allowEgress: false
        ),
        redactor: redactor
      )
      let gate = gate()

      // when
      let coderVerdict = await gate.evaluate(
        call: proposal(),
        tool: coder,
        context: context(fixture.ownerContext, mode: .direct)
      )
      let vmVerdict = await gate.evaluate(
        call: ToolCall(
          id: "vm",
          name: sandboxTool.definition.name,
          argumentsJSON: #"{"language":"sh","code":"true"}"#
        ),
        tool: sandboxTool,
        context: context(fixture.ownerContext, mode: .direct)
      )

      // then
      guard case .requireApproval(let recorded) = coderVerdict else {
        Issue.record("Enabled Coder did not park")
        return
      }
      #expect(recorded.reason == .coderSubmit)
      guard case .block = vmVerdict else {
        Issue.record("VM execution was enabled by the Coder opt-in")
        return
      }
    }
  }

  @Test(arguments: [
    #""owner":7"#, #""source":{"local":{"path":"/fixture/repository-1","credentials":"x"}}"#,
    #""source":{"other":{"path":"/fixture/repository-1"}}"#,
    #""instructions":7"#, #""publish_existing_changes":"true""#,
  ])
  func strictWireShapeRejectsAuthorityAndMalformedFields(_ replacement: String) async throws {
    // given
    let fixture = try CoderServiceFixture()
    try await fixture.withJoinedCleanup {
      try await fixture.service.start()
      let tool = submitTool(fixture)
      let call = proposal(replacing: replacement)

      // when
      let verdict = await gate().evaluate(
        call: call,
        tool: tool,
        context: context(fixture.ownerContext, mode: .direct)
      )

      // then
      guard case .block(let payload, _) = verdict else {
        Issue.record("Malformed Coder wire request reached approval")
        return
      }
      #expect(payload.status == .error)
    }
  }

  @Test func localInferenceScansInstructionsAgainstPrivateText() async throws {
    // given
    let fixture = try CoderServiceFixture()
    try await fixture.withJoinedCleanup {
      try await fixture.service.start()
      let privateText = "The owner's private project is called Operation Nightjar Falcon."
      let call = proposal(replacing: "\"instructions\":\"\(privateText)\"")

      // when
      let verdict = await gate(privateText: privateText).evaluate(
        call: call,
        tool: submitTool(fixture),
        context: context(fixture.ownerContext, mode: .direct)
      )

      // then
      guard case .block(let payload, _) = verdict else {
        Issue.record("Local Coder inference bypassed private-text scanning")
        return
      }
      #expect(payload.status == .blockedArgs)
    }
  }

  @Test(arguments: OutboundScope.allCases)
  func inferenceScansOutboundScope(_ scope: OutboundScope) async throws {
    // given
    let fixture = try CoderServiceFixture()
    try await fixture.withJoinedCleanup {
      try await fixture.service.start()
      let secretRef = "private-reference-token"
      let privateBranch = "release-private-nightjar-falcon"
      let replacement: String
      switch scope {
      case .source:
        replacement = """
          "source":{"local":{"path":"/fixture/sk-abcdefghijklmnop"}},
          "workspace":"\(CoderWorkspaceMode.separate.rawValue)"
          """
      case .startRef:
        replacement = """
          "start_ref":"\(secretRef)","workspace":"\(CoderWorkspaceMode.separate.rawValue)"
          """
      case .baseBranch:
        replacement = """
          "base_branch":"\(privateBranch)","deliverable":"\(CoderDeliverable.pullRequest.rawValue)"
          """
      }

      // when
      let verdict = await gate(privateText: privateBranch, secretValues: [secretRef]).evaluate(
        call: proposal(replacing: replacement),
        tool: submitTool(fixture),
        context: context(fixture.ownerContext, mode: .direct)
      )

      // then
      guard case .block(let payload, _) = verdict else {
        Issue.record("Coder outbound scope reached approval without argument scanning")
        return
      }
      #expect(payload.status == .blockedArgs)
    }
  }

  @Test func statusRedactsAndCapsWorkerResultAsUntrusted() async throws {
    // given
    let secret = #"coder-status-"secret\value"# + "\nline"
    let result = CoderResult(
      state: .succeeded,
      summary: secret + String(repeating: "x", count: ToolOutputCap.maxGraphemes),
      workspacePath: nil,
      startingCommit: nil,
      baselineObserved: false,
      changedFiles: nil,
      branch: nil,
      commit: nil,
      publication: .unknown(reportedURL: nil),
      reportedChecks: [],
      reportedUsage: nil,
      commitAuthor: nil,
      githubActor: nil,
      failure: nil
    )
    let fixture = try CoderServiceFixture(scripts: [.init(result: result)])
    try await fixture.withJoinedCleanup {
      try await fixture.service.start()
      let job = try await fixture.submitFirst()
      fixture.backend.allowCompletion.open()
      #expect(await fixture.jobFinished.waitUntilOpen())
      let tool = CoderStatusTool(
        service: fixture.service,
        redactor: SecretRedactor(secretValues: [secret])
      )

      // when
      let payload = await tool.execute(
        arguments: .object(["job_id": .string(job.id.uuidString)]),
        canonicalTarget: nil,
        context: fixture.ownerContext
      )

      // then
      #expect(payload.status == .ok)
      #expect(payload.ingestedUntrusted)
      #expect(payload.content.contains(secret) == false)
      let containsRedaction = payload.content.contains(SecretRedactor.replacement)
      #expect(containsRedaction)
      #expect(payload.content.count <= ToolOutputCap.maxGraphemes)
      #expect(payload.content.contains(ToolOutputCap.truncationMarker))
    }
  }
}

// MARK: - Fixtures

private extension CoderToolPolicyTests {
  func submitTool(_ fixture: CoderServiceFixture) -> CoderSubmitTool {
    CoderSubmitTool(
      service: fixture.service,
      executionPolicyID: CoderServiceFixture.executionPolicyID,
      redactor: SecretRedactor(secretValues: [])
    )
  }

  func gate(privateText: String = "", secretValues: [String] = []) -> ToolPolicyGate {
    ToolPolicyGate(
      argGuard: ExfilArgGuard(secretValues: secretValues),
      privateFileLoader: { [privateText] },
      enabledDangerousTools: [CoderToolNames.submit]
    )
  }

  func context(_ execution: ToolExecutionContext?, mode: ChatMode) -> ToolDispatchContext {
    ToolDispatchContext(
      sessionTainted: false,
      runIngestedUntrusted: false,
      assemblyPrivateData: false,
      runPrivateData: false,
      sessionHasPrivateData: false,
      approvalAlreadyPending: false,
      mode: mode,
      executionContext: execution
    )
  }

  func proposal(replacing replacement: String = "") -> ToolCall {
    var fields =
      JSONValue.parse(
        """
        {"source":{"local":{"path":"/fixture/repository-1"}},"task":"Fix retry handling",
        "workspace":"inPlace","deliverable":"localChanges"}
        """
      )?.objectValue ?? [:]
    if let extra = JSONValue.parse("{\(replacement)}")?.objectValue {
      fields.merge(extra) { _, new in
        new
      }
    }
    return ToolCall(
      id: "coder",
      name: CoderToolNames.submit,
      argumentsJSON: CanonicalJSON.encode(JSONValue.object(fields)) ?? ""
    )
  }
}
