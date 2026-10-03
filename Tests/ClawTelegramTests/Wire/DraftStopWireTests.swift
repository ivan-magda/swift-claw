import ClawCore
import ClawTelegram
import Foundation
import Testing

@Suite
struct DraftStopWireTests {
  @Test(arguments: ["-9007199254740993", #""-9007199254740993""#])
  func mapsGenerationStopIntoDraftStop(draftID: String) async throws {
    // given
    let json = """
      {"ok":true,"result":[{"update_id":77,"stopped_message_generation":{
      "chat":{"id":42,"type":"private"},"message_thread_id":9,"draft_id":\(draftID)}}]}
      """

    // when
    let updates = try await getUpdates(json: json)
    let raw = try #require(updates.first)

    // then
    #expect(raw.updateID == 77)
    #expect(
      raw.draftStop
        == RawDraftStop(
          chatID: 42,
          chatKind: .private,
          messageThreadID: 9,
          draftID: -9_007_199_254_740_993
        )
    )
    #expect(raw.message == nil)
  }

  @Test(arguments: [
    #"{"chat":{"id":42,"type":"private"}}"#,
    #"{"draft_id":123}"#,
    #"{"chat":{"id":42,"type":"private"},"draft_id":"not-an-id"}"#,
    #"{"chat":{"id":42,"type":"private"},"draft_id":"-9223372036854775809"}"#,
    #"{"chat":{"id":42,"type":"private"},"draft_id":-9223372036854775809}"#,
    #"{"chat":{"id":42,"type":"private"},"draft_id":-123.5}"#,
    #"{"chat":{"id":42,"type":"private"},"draft_id":true}"#,
  ])
  func malformedStopDecodesAsUnactionable(stop: String) async throws {
    // given
    let json = """
      {"ok":true,"result":[
      {"update_id":78,"stopped_message_generation":\(stop)},
      {"update_id":79,"message":{
      "message_id":3,"from":{"id":42},"chat":{"id":42,"type":"private"},"text":"follow-up"}}
      ]}
      """

    // when
    let updates = try await getUpdates(json: json)

    // then
    #expect(updates.map(\.updateID) == [78, 79])
    #expect(updates.first?.draftStop == nil)
    #expect(updates.last?.message?.text == "follow-up")
  }
}

// MARK: - Fixtures

private extension DraftStopWireTests {
  func getUpdates(json: String) async throws -> [RawUpdate] {
    let telegram = TelegramClient(
      token: "T",
      http: MockHTTPExecutor(
        result: HTTPResult(statusCode: 200, headers: [:], body: Data(json.utf8))
      ),
      baseURL: "https://example.test"
    )
    return try await telegram.getUpdates(
      offset: nil,
      timeout: 0,
      allowedUpdates: ["message", "stopped_message_generation"]
    )
  }
}
