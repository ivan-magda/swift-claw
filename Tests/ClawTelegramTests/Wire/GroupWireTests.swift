import ClawCore
import Foundation
import Testing

@testable import ClawTelegram

@Suite struct GroupWireTests {
  private let decoder = JSONDecoder()

  private func rawMessage(_ json: String) throws -> RawMessage {
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))
    return try #require(update.toRawUpdate().message)
  }

  @Test func forumTopicMessageCarriesItsChatKindThreadAndAuthor() throws {
    // given — a message posted in a forum supergroup topic, replying to another attendee
    let json = """
      {
        "update_id": 20,
        "message": {
          "message_id": 500,
          "message_thread_id": 77,
          "from": {"id": 42, "is_bot": false, "first_name": "Ada", "last_name": "Lovelace"},
          "chat": {"id": -1001234, "type": "supergroup", "is_forum": true},
          "reply_to_message": {
            "message_id": 499,
            "from": {"id": 7, "is_bot": true, "username": "claw_bot"}
          },
          "text": "@claw_bot what is the schedule?"
        }
      }
      """

    // when
    let raw = try rawMessage(json)

    // then
    #expect(raw.chatKind == .supergroup)
    #expect(raw.messageThreadId == 77)
    #expect(raw.replyToMessageId == 499)
    #expect(raw.replyToUserId == 7)
    #expect(raw.senderDisplayName == "Ada Lovelace")
    #expect(raw.hasSenderChat == false)
    #expect(raw.migratedToChatId == nil)
  }

  @Test func unknownChatTypeDoesNotDecodeAsPrivate() throws {
    // given — a chat type introduced after this build
    let json = """
      {
        "update_id": 21,
        "message": {
          "message_id": 501,
          "from": {"id": 42},
          "chat": {"id": -100999, "type": "hyperforum"},
          "text": "hi"
        }
      }
      """

    // when
    let raw = try rawMessage(json)

    // then
    #expect(raw.chatKind == .other("hyperforum"))
  }

  @Test func absentChatTypeKeepsTheDirectMessageShape() throws {
    // given — the DM payloads every other suite decodes carry no explicit type
    let json = """
      {
        "update_id": 22,
        "message": {
          "message_id": 502,
          "from": {"id": 42},
          "chat": {"id": 42},
          "text": "hi"
        }
      }
      """

    // when
    let raw = try rawMessage(json)

    // then
    #expect(raw.chatKind == .private)
    #expect(raw.messageThreadId == nil)
    #expect(raw.senderDisplayName == nil)
  }

  @Test func generalTopicHasNoThreadId() throws {
    // given — the General topic of a forum omits message_thread_id entirely
    let json = """
      {
        "update_id": 23,
        "message": {
          "message_id": 503,
          "from": {"id": 42, "first_name": "Ada"},
          "chat": {"id": -1001234, "type": "supergroup", "is_forum": true},
          "text": "hello all"
        }
      }
      """

    // when
    let raw = try rawMessage(json)

    // then — nil, never coerced to the first topic id
    #expect(raw.messageThreadId == nil)
    #expect(raw.senderDisplayName == "Ada")
  }

  @Test func anonymousAdminMessageCarriesItsSenderChat() throws {
    // given — a message sent on behalf of the group, with no usable human sender
    let json = """
      {
        "update_id": 24,
        "message": {
          "message_id": 504,
          "from": {"id": 1087968824, "is_bot": true, "username": "GroupAnonymousBot"},
          "sender_chat": {"id": -1001234, "type": "supergroup"},
          "chat": {"id": -1001234, "type": "supergroup"},
          "text": "announcement"
        }
      }
      """

    // when
    let raw = try rawMessage(json)

    // then
    #expect(raw.hasSenderChat)
  }

  @Test func migratedGroupCarriesItsNewChatId() throws {
    // given — Telegram upgrading a group to a supergroup
    let json = """
      {
        "update_id": 25,
        "message": {
          "message_id": 505,
          "from": {"id": 42},
          "chat": {"id": -400, "type": "group"},
          "text": "x",
          "migrate_to_chat_id": -1001234
        }
      }
      """

    // when
    let raw = try rawMessage(json)

    // then
    #expect(raw.migratedToChatId == -1_001_234)
    #expect(raw.chatKind == .group)
  }

  @Test func displayNameFallsBackToTheUsername() throws {
    // given — a sender with no first_name (bots and some deleted accounts)
    let json = """
      {
        "update_id": 26,
        "message": {
          "message_id": 506,
          "from": {"id": 42, "username": "ada"},
          "chat": {"id": -1001234, "type": "supergroup"},
          "text": "hi"
        }
      }
      """

    // when
    let raw = try rawMessage(json)

    // then
    #expect(raw.senderDisplayName == "ada")
  }
}
