import ClawCore
import Foundation
import Testing

@testable import ClawTelegram

@Suite struct VoiceWireTests {
  private let decoder = JSONDecoder()

  @Test func voiceUpdateCapturesTheDownloadHandle() throws {
    // given — a getUpdates payload carrying a real-client voice note (Ogg/Opus)
    let json = """
      {
        "update_id": 7,
        "message": {
          "message_id": 100,
          "from": {"id": 42, "is_bot": false},
          "chat": {"id": 42},
          "voice": {
            "file_id": "AwACAgIAAxkBAAM",
            "file_unique_id": "AgADuxE",
            "duration": 8,
            "mime_type": "audio/ogg",
            "file_size": 31942
          }
        }
      }
      """

    // when
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))
    let raw = try #require(update.toRawUpdate().message)

    // then — file_id and the guard metadata survive into the wire-agnostic model
    let voice = try #require(raw.voice)
    #expect(voice.fileId == "AwACAgIAAxkBAAM")
    #expect(voice.durationSeconds == 8)
    #expect(voice.mimeType == "audio/ogg")
    #expect(voice.fileSizeBytes == 31_942)
    #expect(raw.mediaKind == VoiceAttachment.mediaKindDescription)
  }

  @Test func voiceWithOptionalFieldsAbsentStillDecodes() throws {
    // given — mime_type and file_size are optional per the Bot API
    let json = """
      {
        "update_id": 8,
        "message": {
          "message_id": 101,
          "from": {"id": 42, "is_bot": false},
          "chat": {"id": 42},
          "voice": {"file_id": "F1", "file_unique_id": "U1", "duration": 3}
        }
      }
      """

    // when
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))

    // then
    let voice = try #require(update.toRawUpdate().message?.voice)
    #expect(voice.fileId == "F1")
    #expect(voice.durationSeconds == 3)
    #expect(voice.mimeType == nil)
    #expect(voice.fileSizeBytes == nil)
  }

  @Test func voiceWithoutAFileIdDegradesToPresenceOnly() throws {
    // given — a malformed (or future-shaped) voice payload with no download handle
    let json = """
      {
        "update_id": 9,
        "message": {
          "message_id": 102,
          "from": {"id": 42, "is_bot": false},
          "chat": {"id": 42},
          "voice": {}
        }
      }
      """

    // when
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))
    let raw = try #require(update.toRawUpdate().message)

    // then — the batch still decodes; the message keeps only the unsupported-media marker
    #expect(raw.voice == nil)
    #expect(raw.mediaKind == VoiceAttachment.mediaKindDescription)
  }

  @Test func getFileResultDecodes() throws {
    // given — the Bot API `File` envelope getFile returns
    let json = """
      {"file_id": "F1", "file_unique_id": "U1", "file_size": 31942, "file_path": "voice/file_3.oga"}
      """

    // when
    let file = try decoder.decode(TFile.self, from: Data(json.utf8))

    // then
    #expect(file.file_id == "F1")
    #expect(file.file_path == "voice/file_3.oga")
  }
}
