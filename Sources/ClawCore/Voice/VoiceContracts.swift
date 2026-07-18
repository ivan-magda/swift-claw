import Foundation

/// Why a transcription attempt failed, typed at the seam so the gateway can map each class to a
/// distinct owner-facing reply without parsing engine error strings. Payloads carry detail for
/// logs only — they must never be echoed to the owner verbatim.
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

/// On-device speech-to-text over a staged audio file. Conformers own engine specifics
/// (locale resolution, model-asset provisioning, decoding); callers own staging and cleanup.
public protocol VoiceTranscribing: Sendable {
  func transcribe(audioFileAt url: URL) async throws(VoiceTranscriptionError) -> String
}

/// The channel-side download seam for a voice attachment: resolve the channel's file handle and
/// return the raw audio bytes, capped at `maxBytes` (an over-cap body must throw, never truncate).
public protocol VoiceMediaFetching: Sendable {
  func downloadVoiceFile(fileId: String, maxBytes: Int) async throws -> Data
}
