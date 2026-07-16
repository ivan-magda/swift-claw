import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawTelegram

@Suite struct VoiceDownloadTests {
  private static let token = "123:SECRET-TOKEN"
  private static let getFileURL = "https://api.telegram.org/bot\(token)/getFile"
  private static let downloadURL = "https://api.telegram.org/file/bot\(token)/voice/file_3.oga"

  private func envelope(filePath: String?) -> HTTPResult {
    let pathField = filePath.map { path in ", \"file_path\": \"\(path)\"" } ?? ""
    let body = """
      {"ok": true, "result": {"file_id": "F1", "file_unique_id": "U1"\(pathField)}}
      """
    return HTTPResult(statusCode: 200, headers: [:], body: Data(body.utf8))
  }

  @Test func downloadsTheResolvedFilePathBounded() async throws {
    // given
    let audio = Data([0x4F, 0x67, 0x67, 0x53])  // "OggS"
    let executor = ClawTestSupport.RecordingHTTPExecutor(responses: [
      Self.getFileURL: envelope(filePath: "voice/file_3.oga"),
      Self.downloadURL: HTTPResult(statusCode: 200, headers: [:], body: audio),
    ])
    let client = TelegramClient(token: Self.token, http: executor)

    // when
    let bytes = try await client.downloadVoiceFile(fileId: "F1", maxBytes: 1024)

    // then — the bytes come back and the GET hit /file/bot<token>/<file_path> under the cap
    #expect(bytes == audio)
    let getCall = try #require(
      await executor.requests.first { request in request.method == .get }
    )
    #expect(getCall.url == Self.downloadURL)
    #expect(getCall.maxBodyBytes == 1024)
  }

  @Test func missingFilePathThrowsWithoutDownloading() async throws {
    // given — Telegram may return a File with no file_path yet
    let executor = ClawTestSupport.RecordingHTTPExecutor(responses: [
      Self.getFileURL: envelope(filePath: nil)
    ])
    let client = TelegramClient(token: Self.token, http: executor)

    // when / then
    await #expect(throws: TelegramError.self) {
      _ = try await client.downloadVoiceFile(fileId: "F1", maxBytes: 1024)
    }
    #expect(await executor.requests.allSatisfy { request in request.method == .post })
  }

  @Test(arguments: ["/etc/passwd", "a/../../b", "x?y=1", "x#frag", "back\\slash"])
  func unsafeFilePathIsRefusedWithoutDownloading(path: String) async throws {
    // given — file_path is server-controlled; anything that could escape the URL prefix is refused
    let executor = ClawTestSupport.RecordingHTTPExecutor(responses: [
      Self.getFileURL: envelope(filePath: path)
    ])
    let client = TelegramClient(token: Self.token, http: executor)

    // when / then
    await #expect(throws: TelegramError.self) {
      _ = try await client.downloadVoiceFile(fileId: "F1", maxBytes: 1024)
    }
    #expect(await executor.requests.allSatisfy { request in request.method == .post })
  }

  @Test func non200DownloadThrowsATypedError() async throws {
    // given
    let executor = ClawTestSupport.RecordingHTTPExecutor(responses: [
      Self.getFileURL: envelope(filePath: "voice/file_3.oga"),
      Self.downloadURL: HTTPResult(statusCode: 404, headers: [:], body: Data()),
    ])
    let client = TelegramClient(token: Self.token, http: executor)

    // when / then
    await #expect(throws: TelegramError.apiError(code: 404, description: "voice download failed")) {
      _ = try await client.downloadVoiceFile(fileId: "F1", maxBytes: 1024)
    }
  }

  @Test func transportErrorIsRedactedBeforeThrowing() async throws {
    // given — a transport failure whose description echoes the token-bearing URL
    struct URLEchoError: Error, CustomStringConvertible {
      let url: String
      var description: String { "connection to \(url) failed" }
    }
    let executor = ClawTestSupport.RecordingHTTPExecutor(
      responses: [Self.getFileURL: envelope(filePath: "voice/file_3.oga")],
      errors: [Self.downloadURL: URLEchoError(url: Self.downloadURL)]
    )
    let client = TelegramClient(token: Self.token, http: executor)

    // when
    do {
      _ = try await client.downloadVoiceFile(fileId: "F1", maxBytes: 1024)
      Issue.record("expected a transport error")
    } catch {
      // then — the thrown message never carries the bot token
      let message = "\(error)"
      #expect(message.contains(Self.token) == false)
      #expect(message.contains(SecretRedactor.replacement))
    }
  }
}
