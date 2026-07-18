import Foundation

public enum VoiceTranscriptionError: Error, Sendable, Equatable {
  /// No speech engine can run on this host (OS too old, ineligible hardware).
  case unavailable
  /// The configured locale is not supported by the installed speech stack.
  case localeUnsupported(String)
  /// The on-device model assets could not be reserved, downloaded, or installed.
  case assetsUnavailable(String)
  /// The staged audio file could not be opened or decoded.
  case undecodableAudio(String)
  /// The DECODED audio runs longer than the engine's configured cap — the ground-truth check
  /// behind the cheap declared-metadata guard, which a forwarded voice note can forge.
  case audioTooLong(seconds: Int)
  /// The engine accepted the audio but failed while producing the transcript.
  case transcriptionFailed(String)
  /// Every configured locale produced only low-confidence output — the audio most likely is not
  /// in any configured language, so no transcript is trustworthy enough to forward.
  case lowConfidence
  /// The surrounding task was cancelled (deadline expiry or shutdown), not an engine fault.
  case cancelled
}

public protocol VoiceTranscribing: Sendable {
  func transcribe(audioFileAt url: URL) async throws(VoiceTranscriptionError) -> String
}

public protocol VoiceMediaFetching: Sendable {
  func downloadVoiceFile(fileId: String, maxBytes: Int) async throws -> Data
}
