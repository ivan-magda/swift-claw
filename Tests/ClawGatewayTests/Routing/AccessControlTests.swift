import ClawCore
import Testing

@testable import ClawGateway

@Suite struct AccessControlTests {
  @Test(
    "allowlist membership",
    arguments: [
      (userId: Int64(42), expected: true),
      (userId: Int64(7), expected: false),
    ]
  )
  func allowlistMembership(userId: Int64, expected: Bool) {
    // given
    let access = AccessControl(allowlist: StubAllowlist(allowed: [42]), groupChats: [])

    // then
    #expect(access.isAllowed(userId: userId) == expected)
  }

  @Test func storeErrorFailsClosed() {
    // given
    let access = AccessControl(allowlist: ThrowingAllowlist(), groupChats: [])

    // then
    #expect(access.isAllowed(userId: 42) == false)
  }

  @Test(
    "the chat-mode decision table",
    arguments: [
      (
        kind: ChatKind.private, chatId: Int64(42), userId: Int64(42),
        expected: AccessDecision.allowed(.direct)
      ),
      (kind: .private, chatId: 7, userId: 7, expected: .denied(.privateStranger)),
      (kind: .supergroup, chatId: -100, userId: 7, expected: .allowed(.group)),
      (kind: .group, chatId: -100, userId: 7, expected: .allowed(.group)),
      (kind: .supergroup, chatId: -200, userId: 42, expected: .denied(.unlistedChat)),
      (kind: .channel, chatId: -100, userId: 42, expected: .denied(.unlistedChat)),
      (kind: .other("gigagroup"), chatId: -100, userId: 42, expected: .denied(.unlistedChat)),
    ]
  )
  func chatModeDecisionTable(
    kind: ChatKind,
    chatId: Int64,
    userId: Int64,
    expected: AccessDecision
  ) {
    // given
    let access = AccessControl(
      allowlist: StubAllowlist(allowed: [42]),
      groupChats: [-100]
    )

    // when
    let decision = access.decide(chatKind: kind, chatId: chatId, userId: userId)

    // then
    #expect(decision == expected)
  }

  @Test func groupModeOffDeniesAnAllowlistedOwnersGroupMessage() {
    // given — no CLAW_GROUP_CHATS configured
    let access = AccessControl(allowlist: StubAllowlist(allowed: [42]), groupChats: [])

    // when
    let decision = access.decide(chatKind: .supergroup, chatId: -100, userId: 42)

    // then
    #expect(decision == .denied(.unlistedChat))
  }

  @Test func aStoreErrorInAPrivateChatFailsClosed() {
    // given
    let access = AccessControl(allowlist: ThrowingAllowlist(), groupChats: [-100])

    // then
    #expect(access.decide(chatKind: .private, chatId: 42, userId: 42) == .denied(.privateStranger))
  }

  @Test func anAllowlistedGroupNeverConsultsTheUserAllowlist() {
    // given — the store would fail closed if it were consulted
    let access = AccessControl(allowlist: ThrowingAllowlist(), groupChats: [-100])

    // then — chat membership is the proof; no per-user check happens
    #expect(access.decide(chatKind: .supergroup, chatId: -100, userId: 7) == .allowed(.group))
  }
}
