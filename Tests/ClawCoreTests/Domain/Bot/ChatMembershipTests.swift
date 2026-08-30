import Testing

@testable import ClawCore

@Suite struct ChatMembershipTests {
  private func membership(
    from old: ChatMembershipStatus,
    to new: ChatMembershipStatus
  ) -> RawChatMemberUpdate {
    RawChatMemberUpdate(
      chatId: -1_001_234,
      chatKind: .supergroup,
      chatTitle: "Podlodka iOS Crew",
      actorUserId: 42,
      actorDisplayName: "Ada Lovelace",
      oldStatus: old,
      newStatus: new
    )
  }

  @Test func statusParsesEveryBotApiSpelling() {
    // given, when, then
    #expect(ChatMembershipStatus(apiValue: "creator") == .creator)
    #expect(ChatMembershipStatus(apiValue: "administrator") == .administrator)
    #expect(ChatMembershipStatus(apiValue: "member") == .member)
    #expect(ChatMembershipStatus(apiValue: "restricted") == .restricted)
    #expect(ChatMembershipStatus(apiValue: "left") == .left)
    #expect(ChatMembershipStatus(apiValue: "kicked") == .kicked)
  }

  @Test func anUnknownStatusKeepsItsSpellingAndCountsAsPresent() {
    // given — a status introduced after this build
    let status = ChatMembershipStatus(apiValue: "shadowbanned")

    // when, then — never read as a removal, and the operator still sees the word
    #expect(status == .other("shadowbanned"))
    #expect(status.apiValue == "shadowbanned")
    #expect(status.isPresent)
  }

  @Test func joiningAChatReadsAsAdded() {
    // given, when
    let change = membership(from: .left, to: .member).change

    // then
    #expect(change == .added)
  }

  @Test func beingRemovedReadsAsRemoved() {
    // given, when — an admin kicks the bot
    #expect(membership(from: .administrator, to: .kicked).change == .removed)
    #expect(membership(from: .member, to: .left).change == .removed)
  }

  @Test func aRightsChangeInsideTheChatReadsAsUpdated() {
    // given, when — promoted to admin, which is how a group grants it message access
    #expect(membership(from: .member, to: .administrator).change == .updated)
    #expect(membership(from: .administrator, to: .restricted).change == .updated)
  }

  @Test func anIdenticalStatusReadsAsUnchanged() {
    // given, when, then
    #expect(membership(from: .member, to: .member).change == .unchanged)
    #expect(membership(from: .left, to: .kicked).change == .unchanged)
  }
}
