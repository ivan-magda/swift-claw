import Testing

@testable import ClawCore

@Suite struct ChatKindTests {
  @Test func knownApiValuesMapToTheirCase() {
    // given / when / then
    #expect(ChatKind(apiValue: "private") == .private)
    #expect(ChatKind(apiValue: "group") == .group)
    #expect(ChatKind(apiValue: "supergroup") == .supergroup)
    #expect(ChatKind(apiValue: "channel") == .channel)
  }

  @Test func unrecognizedApiValueIsNeverPrivate() {
    // given — a chat type this build has never heard of
    let kind = ChatKind(apiValue: "hyperforum")

    // then — it keeps the raw string and stays out of the DM case
    #expect(kind == .other("hyperforum"))
    #expect(kind != .private)
    #expect(kind.isGroupChat == false)
  }

  @Test func onlyGroupAndSupergroupCountAsGroupChats() {
    // given / when / then
    #expect(ChatKind.group.isGroupChat)
    #expect(ChatKind.supergroup.isGroupChat)
    #expect(ChatKind.private.isGroupChat == false)
    #expect(ChatKind.channel.isGroupChat == false)
  }

  @Test func apiValueRoundTrips() {
    // given
    let kinds: [ChatKind] = [.private, .group, .supergroup, .channel, .other("hyperforum")]

    // when / then
    for kind in kinds {
      #expect(ChatKind(apiValue: kind.apiValue) == kind)
    }
  }
}
