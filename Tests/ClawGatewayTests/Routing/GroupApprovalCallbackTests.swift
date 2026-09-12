import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct GroupApprovalCallbackTests {
  private func handler(
    _ fixture: GroupApprovalFixture,
    membership: GroupMembershipStub = GroupMembershipStub(
      chatId: GroupApprovalFixture.chatId,
      memberUserIds: [GroupApprovalFixture.requesterId, GroupApprovalFixture.participantId]
    ),
    groupAllowed: Bool = true
  ) -> ApprovalCallbackHandler {
    let transport = RecordingTransport()
    return ApprovalCallbackHandler.make(
      processed: ProcessedUpdateStoreGRDB(writer: fixture.queue),
      delivery: transport,
      accessControl: AccessControl(
        allowlist: AllowlistStoreGRDB(writer: fixture.queue),
        groupChats: groupAllowed ? [GroupApprovalFixture.chatId] : []
      ),
      approvals: fixture.approvals,
      runs: fixture.runs,
      membership: membership,
      audit: AuditLogGRDB(writer: fixture.queue),
      coordinator: ApprovalCoordinator(),
      callbacks: transport,
      currentPolicyVersion: { GroupApprovalFixture.policyVersion },
      now: { GroupApprovalFixture.now },
      logger: TestLog.silent
    )
  }

  @Test func onlyConferenceRequesterCanResolve() async throws {
    // given
    let fixture = try GroupApprovalFixture(
      reason: .conferenceSubmit,
      tool: ConferenceToolNames.submit
    )
    let callbackHandler = handler(fixture)

    // when — another current member taps the original prompt.
    _ = await callbackHandler.handle(fixture.callback(), updateId: 2)

    // then — their decision cannot replace the participant's consent.
    #expect(try fixture.approvals.approval(id: fixture.approval.id)?.state == .pending)
    _ = await callbackHandler.handle(
      fixture.callback(from: GroupApprovalFixture.requesterId),
      updateId: 3
    )
    #expect(try fixture.approvals.approval(id: fixture.approval.id)?.state == .approved)
  }

  @Test(arguments: [true, false])
  func currentParticipantCanResolveWithoutOwnerAllowlist(approve: Bool) async throws {
    let fixture = try GroupApprovalFixture()
    let callbackHandler = handler(fixture)

    _ = await callbackHandler.handle(fixture.callback(approve: approve), updateId: 2)

    let expectedState: ApprovalState = approve ? .approved : .rejected
    let expectedAction: AuditAction = approve ? .approvalGranted : .approvalDenied
    #expect(try fixture.approvals.approval(id: fixture.approval.id)?.state == expectedState)
    let row = try await fixture.queue.read { database in
      try Row.fetchOne(
        database,
        sql: "SELECT actor, actor_user_id FROM audit_events WHERE action = ?",
        arguments: [expectedAction.rawValue]
      )
    }
    let grant = try #require(row)
    #expect(grant["actor"] as String == AuditActor.groupMember.rawValue)
    #expect(grant["actor_user_id"] as Int64 == GroupApprovalFixture.participantId)
  }

  enum Refusal: CaseIterable {
    case removedMember, unavailableMembership, unlistedGroup, copiedChat, copiedMessage
    case undeliveredPrompt, missingRequester, wrongSession, mismatchedChat, wrongReason, wrongTool
  }

  @Test(arguments: Refusal.allCases)
  func invalidGroupAuthorityLeavesApprovalPending(refusal: Refusal) async throws {
    let fixture = try GroupApprovalFixture(
      reason: refusal == .wrongReason ? .codeExec : .coderSubmit,
      tool: refusal == .wrongTool ? "execute_code" : CoderToolNames.submit
    )
    try await fixture.queue.write { database in
      switch refusal {
      case .missingRequester:
        try database.execute(sql: "UPDATE runs SET requester_user_id = NULL")
      case .wrongSession:
        try database.execute(
          sql: "INSERT INTO sessions(session_key, created_ts, updated_ts) VALUES (?, ?, ?)",
          arguments: [
            SessionKey.telegramDM(chatId: 99), GroupApprovalFixture.now,
            GroupApprovalFixture.now,
          ]
        )
        try database.execute(
          sql: "UPDATE approvals SET session_id = ?",
          arguments: [database.lastInsertedRowID]
        )
      case .mismatchedChat:
        try database.execute(sql: "UPDATE approvals SET owner_user_id = owner_user_id - 1")
      case .undeliveredPrompt:
        try database.execute(sql: "UPDATE approvals SET prompt_message_id = NULL")
      default:
        break
      }
    }
    let callbackHandler = handler(
      fixture,
      membership: GroupMembershipStub(
        chatId: GroupApprovalFixture.chatId,
        memberUserIds: refusal == .removedMember ? [] : [GroupApprovalFixture.participantId],
        fails: refusal == .unavailableMembership
      ),
      groupAllowed: refusal != .unlistedGroup
    )
    let callback = fixture.callback(
      chatId: refusal == .copiedChat ? -100_456 : GroupApprovalFixture.chatId,
      messageId: refusal == .undeliveredPrompt
        ? nil : (refusal == .copiedMessage ? 901 : GroupApprovalFixture.promptMessageId)
    )

    _ = await callbackHandler.handle(callback, updateId: 2)

    #expect(try fixture.approvals.approval(id: fixture.approval.id)?.state == .pending)
    let decisions = try await fixture.queue.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM audit_events WHERE action IN (?, ?)",
        arguments: [AuditAction.approvalGranted.rawValue, AuditAction.approvalDenied.rawValue]
      )
    }
    #expect(decisions == 0)
  }
}
