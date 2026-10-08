import ClawCore
import Foundation
import Testing

@testable import ClawTelegram

@Suite
struct JournalTimestampWireTests {
  @Test(
    arguments: [
      (edited: false, dates: "\"date\": 1728345600,", expected: 1_728_345_600.0),
      (
        edited: true,
        dates: "\"date\": 1728345600, \"edit_date\": 1728349200,",
        expected: 1_728_349_200.0
      ),
      (edited: false, dates: "", expected: nil),
      (edited: true, dates: "\"date\": 1728345600,", expected: nil),
    ] as [(edited: Bool, dates: String, expected: TimeInterval?)]
  )
  func timestampsSurviveWireAndNormalization(
    edited: Bool,
    dates: String,
    expected: TimeInterval?
  ) throws {
    // given
    let field = edited ? "edited_message" : "message"
    let json = """
      {"update_id": 7, "\(field)": {
        "message_id": 100, "from": {"id": 42}, "chat": {"id": 42},
        \(dates) "caption": "Useful media caption", "document": {}
      }}
      """

    // when
    let wire = try JSONDecoder().decode(TUpdate.self, from: Data(json.utf8))
    let incoming = try #require(IncomingMessage.normalize(from: wire.toRawUpdate()))

    // then
    let editInstant = expected.map(Date.init(timeIntervalSince1970:))
    #expect(incoming.sourceTimestamp == editInstant)
  }
}
