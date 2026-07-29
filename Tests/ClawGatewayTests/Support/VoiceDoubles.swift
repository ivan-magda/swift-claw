import ClawCore
import ClawGateway
import Foundation

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

/// Parks its FIRST call until the surrounding task is cancelled — a cancellable wait, not a
/// timing sleep — then transcribes normally on every later call. Covers both halves of the
/// cancellation story: a wedged engine the deadline race abandons, and a shutdown-cancelled
/// intake whose redelivery re-transcribes after restart.
struct ParkUntilCancelledTranscriber: VoiceTranscribing {
  let calls = CallCounter()
  var transcript = "spoken words"

  func transcribe(audioFileAt url: URL) async throws(VoiceTranscriptionError) -> String {
    guard await calls.next() > 1 else {
      try? await Task.sleep(for: .seconds(3_600))
      throw VoiceTranscriptionError.cancelled
    }
    return transcript
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
