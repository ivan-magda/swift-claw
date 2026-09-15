import ClawCore
import Testing

@testable import ClawGateway

@Suite
struct AccessControlTests {
  @Test(
    "allowlist membership",
    arguments: [(userID: (42 as Int64), expected: true), (userID: (7 as Int64), expected: false)]
  )
  func allowlistMembership(userID: Int64, expected: Bool) {
    // given
    let access = AccessControl(allowlist: StubAllowlist(allowed: [42]), groupChats: [])

    // then
    #expect(access.isAllowed(userID: userID) == expected)
  }

  @Test
  func storeErrorFailsClosed() {
    // given
    let access = AccessControl(allowlist: ThrowingAllowlist(), groupChats: [])

    // then
    #expect(access.isAllowed(userID: 42) == false)
  }

  @Test(
    "the chat-mode decision table",
    arguments: [
      (
        kind: ChatKind.private,
        chatID: (42 as Int64),
        userID: (42 as Int64),
        expected: AccessDecision.allowed(.direct)
      ),
      (kind: .private, chatID: 7, userID: 7, expected: .denied(.privateStranger)),
      (kind: .supergroup, chatID: -100, userID: 7, expected: .allowed(.group)),
      (kind: .group, chatID: -100, userID: 7, expected: .allowed(.group)),
      (kind: .supergroup, chatID: -200, userID: 42, expected: .denied(.unlistedChat)),
      (kind: .channel, chatID: -100, userID: 42, expected: .denied(.unlistedChat)),
      (kind: .other("gigagroup"), chatID: -100, userID: 42, expected: .denied(.unlistedChat)),
    ]
  )
  func chatModeDecisionTable(kind: ChatKind, chatID: Int64, userID: Int64, expected: AccessDecision)
  {
    // given
    let access = AccessControl(allowlist: StubAllowlist(allowed: [42]), groupChats: [-100])

    // when
    let decision = access.decide(chatKind: kind, chatID: chatID, userID: userID)

    // then
    #expect(decision == expected)
  }

  @Test
  func groupModeOffDeniesAnAllowlistedOwnersGroupMessage() {
    // given — no CLAW_GROUP_CHATS configured
    let access = AccessControl(allowlist: StubAllowlist(allowed: [42]), groupChats: [])

    // when
    let decision = access.decide(chatKind: .supergroup, chatID: -100, userID: 42)

    // then
    #expect(decision == .denied(.unlistedChat))
  }

  @Test
  func aStoreErrorInAPrivateChatFailsClosed() {
    // given
    let access = AccessControl(allowlist: ThrowingAllowlist(), groupChats: [-100])

    // then
    #expect(access.decide(chatKind: .private, chatID: 42, userID: 42) == .denied(.privateStranger))
  }

  @Test
  func anAllowlistedGroupNeverConsultsTheUserAllowlist() {
    // given — the store would fail closed if it were consulted
    let access = AccessControl(allowlist: ThrowingAllowlist(), groupChats: [-100])

    // then — chat membership is the proof; no per-user check happens
    #expect(access.decide(chatKind: .supergroup, chatID: -100, userID: 7) == .allowed(.group))
  }
}
