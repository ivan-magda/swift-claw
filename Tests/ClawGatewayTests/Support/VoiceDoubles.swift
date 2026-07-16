import ClawCore
import ClawGateway
import Foundation

/// The one fetcher double for the `VoiceMediaFetching` seam: returns canned bytes or throws, and
/// records every call's fileId AND maxBytes so tests can assert both what was fetched and that
/// the bounded-download cap survives the middle of the chain.
struct StubVoiceFetcher: VoiceMediaFetching {
  struct FetchCall: Sendable, Equatable {
    let fileId: String
    let maxBytes: Int
  }

  actor Recorder {
    private(set) var calls: [FetchCall] = []

    func append(_ call: FetchCall) {
      calls.append(call)
    }
  }

  struct FetchFailed: Error {}

  let recorder = Recorder()
  var audio: Data? = Data([0x4F, 0x67, 0x67, 0x53])  // "OggS"

  func downloadVoiceFile(fileId: String, maxBytes: Int) async throws -> Data {
    await recorder.append(FetchCall(fileId: fileId, maxBytes: maxBytes))
    guard let audio else {
      throw FetchFailed()
    }
    return audio
  }
}

/// The one transcriber double for the `VoiceTranscribing` seam: scripted success or typed failure.
struct StubVoiceTranscriber: VoiceTranscribing {
  var result: Result<String, VoiceTranscriptionError> = .success("spoken words")

  func transcribe(audioFileAt url: URL) async throws(VoiceTranscriptionError) -> String {
    switch result {
    case .success(let transcript):
      return transcript
    case .failure(let error):
      throw error
    }
  }
}

/// Scripts the ROUTER-facing seam directly, for outcomes the real service only produces under
/// real filesystem/engine conditions (`.storageFull`, `.timedOut`).
struct ScriptedVoiceService: VoiceMessageTranscribing {
  var result: Result<String, VoiceMessageService.Failure>

  func transcribe(
    _ attachment: VoiceAttachment
  ) async -> Result<String, VoiceMessageService.Failure> {
    result
  }
}
