import ClawCore
import Foundation
import Testing

@testable import ClawTelegram

@Suite struct CallbackWireTests {
  private let decoder = JSONDecoder()

  @Test func decodesACallbackQueryUpdate() throws {
    // given — a getUpdates payload carrying a callback_query (an inline-button tap)
    let json = """
      {
        "update_id": 42,
        "callback_query": {
          "id": "cbq-1",
          "from": {"id": 7, "is_bot": false, "username": "owner"},
          "message": {"message_id": 500, "chat": {"id": 7}},
          "data": "apr:abc123:y"
        }
      }
      """

    // when
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))

    // then — the fields the §6.2 auth chain binds to; `from` is never absent for a callback
    let callback = try #require(update.callback_query)
    #expect(callback.id == "cbq-1")
    #expect(callback.from.id == 7)
    #expect(callback.message?.message_id == 500)
    #expect(callback.data == "apr:abc123:y")
  }

  @Test func plainMessageUpdateHasNoCallback() throws {
    // given — an ordinary text update with no callback_query key
    let json = """
      {"update_id": 1, "message": {"message_id": 9, "chat": {"id": 7}, "text": "hi"}}
      """

    // when
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))

    // then — the added optional is absent and the existing message mapping is unchanged
    #expect(update.callback_query == nil)
    #expect(update.toRawUpdate().message?.text == "hi")
  }
}
