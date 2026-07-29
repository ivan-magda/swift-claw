import ClawCore
import Foundation
import Testing

@testable import ClawTelegram

@Suite struct PhotoWireTests {
  private let decoder = JSONDecoder()

  @Test func photoUpdateCapturesTheWholeSizeLadder() throws {
    // given — a getUpdates payload carrying a real-client compressed photo
    let json = """
      {
        "update_id": 11,
        "message": {
          "message_id": 200,
          "from": {"id": 42, "is_bot": false},
          "chat": {"id": 42},
          "caption": "what is this?",
          "photo": [
            {"file_id": "s-id", "file_unique_id": "s-u", "width": 90, "height": 67,
             "file_size": 1466},
            {"file_id": "x-id", "file_unique_id": "x-u", "width": 800, "height": 600,
             "file_size": 61234},
            {"file_id": "y-id", "file_unique_id": "y-u", "width": 1280, "height": 960,
             "file_size": 186422}
          ]
        }
      }
      """

    // when
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))
    let raw = try #require(update.toRawUpdate().message)

    // then — every rung survives, and the caption rides alongside rather than replacing it
    let photo = try #require(raw.photo)
    #expect(photo.sizes.count == 3)
    #expect(photo.sizes.map(\.fileId) == ["s-id", "x-id", "y-id"])
    #expect(photo.sizes[2].width == 1280)
    #expect(photo.sizes[2].height == 960)
    #expect(photo.sizes[2].fileSizeBytes == 186_422)
    #expect(raw.caption == "what is this?")
    #expect(raw.mediaKind == PhotoAttachment.mediaKindDescription)
  }

  @Test func rungsWithOptionalFieldsAbsentStillDecode() throws {
    // given — file_size is emitted only when non-zero, per the Bot API
    let json = """
      {
        "update_id": 12,
        "message": {
          "message_id": 201,
          "from": {"id": 42, "is_bot": false},
          "chat": {"id": 42},
          "photo": [{"file_id": "y-id", "width": 1280, "height": 960}]
        }
      }
      """

    // when
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))
    let raw = try #require(update.toRawUpdate().message)

    // then
    let photo = try #require(raw.photo)
    #expect(photo.sizes.count == 1)
    #expect(photo.sizes[0].fileSizeBytes == nil)
    #expect(photo.sizes[0].fileUniqueId == nil)
  }

  @Test func malformedRungsDegradeToPresenceOnlyWithoutFailingTheBatch() throws {
    // given — a rung missing file_id, which no future API shape may be allowed to turn into a
    // decode failure that stalls the whole getUpdates batch
    let json = """
      {
        "update_id": 13,
        "message": {
          "message_id": 202,
          "from": {"id": 42, "is_bot": false},
          "chat": {"id": 42},
          "photo": [{"width": 1280, "height": 960}]
        }
      }
      """

    // when
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))
    let raw = try #require(update.toRawUpdate().message)

    // then — no usable rung means no attachment, but the unsupported-media path still works
    #expect(raw.photo == nil)
    #expect(raw.mediaKind == PhotoAttachment.mediaKindDescription)
  }
}
