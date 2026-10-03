import ClawCore
import Foundation
import Testing

@testable import ClawTelegram

@Suite
struct DraftStopWireTests {
  @Test
  func mapsGenerationStopIntoDraftStop() throws {
    // given
    let json = """
      {"update_id":77,"stopped_message_generation":{
      "chat":{"id":42,"type":"private"},"message_thread_id":9,"draft_id":-123}}
      """

    // when
    let raw = try JSONDecoder().decode(TUpdate.self, from: Data(json.utf8)).toRawUpdate()

    // then
    #expect(raw.updateID == 77)
    #expect(
      raw.draftStop
        == RawDraftStop(
          chatID: 42,
          chatKind: .private,
          messageThreadID: 9,
          draftID: -123
        )
    )
    #expect(raw.message == nil)
  }

  @Test(arguments: [
    #"{"chat":{"id":42,"type":"private"}}"#,
    #"{"draft_id":123}"#,
  ])
  func malformedStopDecodesAsUnactionable(stop: String) throws {
    // given
    let json = "{\"update_id\":78,\"stopped_message_generation\":\(stop)}"

    // when
    let raw = try JSONDecoder().decode(TUpdate.self, from: Data(json.utf8)).toRawUpdate()

    // then
    #expect(raw.draftStop == nil)
  }
}
