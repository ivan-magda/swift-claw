import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct GroupApprovalResumeTests {
  private struct ContextEchoTool: Tool {
    let toolName: String

    var definition: ToolDefinition {
      ToolDefinition(
        name: toolName,
        description: "Returns the trusted execution identity.",
        parameters: .object([:]),
        metadataProvenance: .trusted,
        egressClass: .none,
        riskLevel: .dangerous,
        requiresInteractiveRequester: true
      )
    }
    let timeout: Duration = .seconds(1)

    func canonicalTarget(arguments: JSONValue) -> CanonicalTargetResolution? { nil }

    func execute(arguments: JSONValue, canonicalTarget: String?) async -> ToolPayload {
      ToolPayload(content: "context missing", status: .error, ingestedUntrusted: false)
    }

    func execute(
      arguments: JSONValue,
      canonicalTarget: String?,
      context: ToolExecutionContext?
    ) async -> ToolPayload {
      let value = JSONValue.object([
        "requester": .string(context?.requesterUserId.map(String.init) ?? "missing"),
        "chat": .string(context.map { String($0.chatId) } ?? "missing"),
        "mode": .string(context?.mode.rawValue ?? "missing"),
        "origin": .string(context?.origin.rawValue ?? "missing"),
        "args": arguments,
        "target": .string(canonicalTarget ?? "missing"),
      ])
      return ToolPayload(
        content: CanonicalJSON.encode(value) ?? "invalid",
        status: .ok,
        ingestedUntrusted: false
      )
    }
  }

  private struct TypingGatedFailure: ApprovedActionExecuting {
    let gate: TypingReleaseGate

    func executeApproved(_ approval: Approval) async -> ApprovedCommitOutcome {
      await gate.awaitRelease()
      return .storeFailed
    }
  }

  private func executor(_ fixture: GroupApprovalFixture) -> ApprovedActionExecutor {
    ApprovedActionExecutor(
      tools: [fixture.approval.tool: ContextEchoTool(toolName: fixture.approval.tool)],
      runs: fixture.runs,
      redactArguments: { value in
        value
      },
      now: { GroupApprovalFixture.now },
      logger: TestLog.silent
    )
  }

  private func approved(_ fixture: GroupApprovalFixture) throws -> Approval {
    _ = try fixture.approvals.approve(
      id: fixture.approval.id,
      currentPolicyVersion: GroupApprovalFixture.policyVersion,
      actor: ApprovalResolutionActor(
        actor: .groupMember,
        userId: GroupApprovalFixture.participantId
      ),
      now: GroupApprovalFixture.now
    )
    return try #require(try fixture.approvals.approval(id: fixture.approval.id))
  }

  @Test func approvedGroupActionNeverInfersMissingRequesterFromChatOrApprover() async throws {
    // given
    let fixture = try GroupApprovalFixture()
    let approval = try approved(fixture)
    try await fixture.queue.write { database in
      try database.execute(sql: "UPDATE runs SET requester_user_id = NULL")
    }

    // when
    let outcome = await executor(fixture).executeApproved(approval)

    // then
    #expect(outcome == .committed)
    let status = try await fixture.queue.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT decision FROM audit_events WHERE run_id = ? AND action = ?",
        arguments: [approval.runId, AuditAction.toolCall.rawValue]
      )
    }
    #expect(status == ToolObservationStatus.error.rawValue)
  }

  @Test func approvedConferenceActionRestoresOriginalRequest() async throws {
    // given
    let fixture = try GroupApprovalFixture(
      reason: .conferenceSubmit,
      tool: ConferenceToolNames.submit
    )
    _ = try fixture.approvals.approve(
      id: fixture.approval.id,
      currentPolicyVersion: GroupApprovalFixture.policyVersion,
      actor: ApprovalResolutionActor(
        actor: .groupMember,
        userId: GroupApprovalFixture.requesterId
      ),
      now: GroupApprovalFixture.now
    )
    let approval = try #require(try fixture.approvals.approval(id: fixture.approval.id))

    // when
    let outcome = await executor(fixture).executeApproved(approval)

    // then
    #expect(outcome == .committed)
    let content = try await fixture.queue.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [approval.observationMessageId]
      )
    }
    let observation = try #require(content)
    let result = try #require(JSONValue.parse(observation)?.objectValue)
    #expect(result["requester"] == .string(String(GroupApprovalFixture.requesterId)))
    #expect(result["chat"] == .string(String(GroupApprovalFixture.chatId)))
    #expect(result["mode"] == .string(ChatMode.group.rawValue))
    #expect(result["args"] == JSONValue.parse(approval.canonicalArgsJSON))
    #expect(result["target"] == .string(approval.canonicalTarget))
  }

  @Test func deniedGroupNoticeRepliesInOriginalTopicAndDisarmsOriginalPrompt() async throws {
    // given
    let fixture = try GroupApprovalFixture()
    let coordinator = ApprovalCoordinator()
    let transport = RecordingTransport()
    _ = try fixture.approvals.deny(
      id: fixture.approval.id,
      decision: .rejected,
      now: GroupApprovalFixture.now
    )
    await coordinator.signal(approvalId: fixture.approval.id, .denied(.rejected))
    let waiter = waiter(fixture, coordinator: coordinator, transport: transport)

    // when
    await park(waiter, fixture: fixture)

    // then
    let sent = await transport.sent
    #expect(
      sent.map(\.target) == [
        DeliveryTarget(
          chatId: GroupApprovalFixture.chatId,
          messageThreadId: 77,
          replyToMessageId: 88
        )
      ]
    )
    let edits = await transport.markupEdits
    #expect(
      edits == [
        RecordingTransport.MarkupEdit(
          chatId: GroupApprovalFixture.chatId,
          messageId: GroupApprovalFixture.promptMessageId,
          replyMarkup: nil
        )
      ]
    )
  }

  @Test func approvedGroupTypingAndFailureNoticeUseOriginalTopic() async throws {
    // given
    let fixture = try GroupApprovalFixture()
    _ = try approved(fixture)
    let coordinator = ApprovalCoordinator()
    let transport = RecordingTransport()
    let gate = TypingReleaseGate()
    let typing = CountingReleaseTyping(releaseAfter: 1, gate: gate)
    let waiter = waiter(
      fixture,
      coordinator: coordinator,
      transport: transport,
      actionExecutor: TypingGatedFailure(gate: gate),
      typing: typing
    )
    await coordinator.signal(approvalId: fixture.approval.id, .approved)

    // when
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await park(waiter, fixture: fixture)
      }
      let sawTyping = await gate.waitUntilReleased()
      await gate.release()
      #expect(sawTyping)
      await group.waitForAll()
    }

    // then
    let sent = await transport.sent
    #expect(
      sent.map(\.target) == [
        DeliveryTarget(
          chatId: GroupApprovalFixture.chatId,
          messageThreadId: 77,
          replyToMessageId: 88
        )
      ]
    )
    let pulses = await typing.pulses
    #expect(
      pulses.contains(
        RecordingTyping.Pulse(chatId: GroupApprovalFixture.chatId, messageThreadId: 77)
      )
    )
  }

  @Test func unreadableGroupDestinationNeverFallsBackToWholeChat() async throws {
    // given
    let fixture = try GroupApprovalFixture()
    let coordinator = ApprovalCoordinator()
    let transport = RecordingTransport()
    _ = try fixture.approvals.deny(
      id: fixture.approval.id,
      decision: .rejected,
      now: GroupApprovalFixture.now
    )
    try await fixture.queue.write { database in
      try database.execute(sql: "UPDATE sessions SET session_key = 'tg:topic:broken:77'")
    }
    await coordinator.signal(approvalId: fixture.approval.id, .denied(.rejected))
    let waiter = waiter(fixture, coordinator: coordinator, transport: transport)

    // when
    await park(waiter, fixture: fixture)

    // then
    #expect(await transport.sent.isEmpty)
    #expect(await transport.markupEdits.count == 1)
  }
}

// MARK: - Waiter Fixture

private extension GroupApprovalResumeTests {
  func waiter(
    _ fixture: GroupApprovalFixture,
    coordinator: ApprovalCoordinator,
    transport: RecordingTransport,
    actionExecutor: (any ApprovedActionExecuting)? = nil,
    typing: any TypingIndicator = NoopTyping()
  ) -> ApprovalWaiter {
    ApprovalWaiter(
      approvals: fixture.approvals,
      runs: fixture.runs,
      coordinator: coordinator,
      executor: actionExecutor ?? executor(fixture),
      turns: FakeTurnRunner(),
      delivery: transport,
      callbacks: transport,
      typing: typing,
      clock: ContinuousClock(),
      currentPolicyVersion: { GroupApprovalFixture.policyVersion },
      now: { GroupApprovalFixture.now },
      logger: TestLog.silent
    )
  }

  func park(_ waiter: ApprovalWaiter, fixture: GroupApprovalFixture) async {
    await waiter.park(
      approvalId: fixture.approval.id,
      runId: fixture.approval.runId,
      sessionId: fixture.approval.sessionId,
      chatId: GroupApprovalFixture.chatId,
      revalidatePolicyOnApprove: false
    )
  }
}
