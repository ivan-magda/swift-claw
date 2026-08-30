import ClawCore
import Foundation
import Testing

@testable import ClawTelegram

/// `my_chat_member` is the only update that tells the daemon it was added to, removed from, or
/// re-permissioned in a room. It is observed, never acted on, so decoding keeps just what the
/// operator-facing log prints.
@Suite struct MembershipWireTests {
  private let decoder = JSONDecoder()

  private func membership(_ json: String) throws -> RawChatMemberUpdate {
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))
    return try #require(update.toRawUpdate().myChatMember)
  }

  @Test func addingTheBotToAForumDecodesTheChatAndBothStatuses() throws {
    // given — an admin adds the bot to a forum supergroup
    let json = """
      {
        "update_id": 30,
        "my_chat_member": {
          "chat": {"id": -1001234, "type": "supergroup", "is_forum": true, "title": "Podlodka"},
          "from": {"id": 42, "is_bot": false, "first_name": "Ada", "last_name": "Lovelace"},
          "date": 1750000000,
          "old_chat_member": {"user": {"id": 900, "is_bot": true}, "status": "left"},
          "new_chat_member": {"user": {"id": 900, "is_bot": true}, "status": "member"}
        }
      }
      """

    // when
    let update = try membership(json)

    // then
    #expect(update.chatId == -1_001_234)
    #expect(update.chatKind == .supergroup)
    #expect(update.chatTitle == "Podlodka")
    #expect(update.actorUserId == 42)
    #expect(update.actorDisplayName == "Ada Lovelace")
    #expect(update.oldStatus == .left)
    #expect(update.newStatus == .member)
    #expect(update.change == .added)
  }

  @Test func aStatusThisBuildHasNeverSeenSurvivesVerbatim() throws {
    // given
    let json = """
      {
        "update_id": 31,
        "my_chat_member": {
          "chat": {"id": -1001234, "type": "supergroup"},
          "old_chat_member": {"status": "member"},
          "new_chat_member": {"status": "hyperadmin"}
        }
      }
      """

    // when
    let update = try membership(json)

    // then
    #expect(update.newStatus == .other("hyperadmin"))
    #expect(update.actorUserId == nil)
  }

  @Test func aMembershipUpdateCarriesNoMessage() throws {
    // given
    let json = """
      {
        "update_id": 32,
        "my_chat_member": {
          "chat": {"id": -1001234, "type": "supergroup"},
          "old_chat_member": {"status": "member"},
          "new_chat_member": {"status": "kicked"}
        }
      }
      """

    // when
    let raw = try decoder.decode(TUpdate.self, from: Data(json.utf8)).toRawUpdate()

    // then — nothing for the message pipeline to normalize
    #expect(raw.message == nil)
    #expect(raw.editedMessage == nil)
    #expect(raw.callback == nil)
    #expect(raw.myChatMember?.change == .removed)
  }

  @Test func anUpdateKindThisBuildDoesNotDecodeStaysEmpty() throws {
    // given — a kind never listed in allowedUpdates, delivered anyway
    let json = """
      {"update_id": 33, "poll_answer": {"poll_id": "1", "option_ids": [0]}}
      """

    // when
    let raw = try decoder.decode(TUpdate.self, from: Data(json.utf8)).toRawUpdate()

    // then — decoded without throwing, and carrying nothing to route
    #expect(raw.updateId == 33)
    #expect(raw.message == nil)
    #expect(raw.myChatMember == nil)
  }
}
