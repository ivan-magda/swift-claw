import Foundation
import Testing

@testable import ClawCore
@testable import ClawTelegram

@Suite struct CallbackUpdateMappingTests {
  @Test func mapsCallbackQueryIntoRawUpdateCallback() throws {
    // given — a Bot API update carrying only a callback_query (no message/edited_message)
    let json = """
      {"update_id":77,"callback_query":{"id":"cbX","from":{"id":42},
      "message":{"message_id":9,"chat":{"id":99}},"data":"apr:NONCE:y"}}
      """

    // when
    let update = try JSONDecoder().decode(TUpdate.self, from: Data(json.utf8))
    let raw = update.toRawUpdate()

    // then — the callback rides RawUpdate.callback; message/edited stay nil; chat/message ids come
    // from the prompt message (callback.message)
    let callback = try #require(raw.callback)
    #expect(raw.message == nil)
    #expect(raw.editedMessage == nil)
    #expect(callback.callbackId == "cbX")
    #expect(callback.fromUserId == 42)
    #expect(callback.chatId == 99)
    #expect(callback.messageId == 9)
    #expect(callback.data == "apr:NONCE:y")
  }

  @Test func plainMessageUpdateHasNilCallback() throws {
    // given
    let json = """
      {"update_id":78,"message":{"message_id":3,"from":{"id":42},"chat":{"id":42},"text":"hi"}}
      """

    // when
    let raw = try JSONDecoder().decode(TUpdate.self, from: Data(json.utf8)).toRawUpdate()

    // then
    #expect(raw.callback == nil)
    #expect(raw.message != nil)
  }
}
