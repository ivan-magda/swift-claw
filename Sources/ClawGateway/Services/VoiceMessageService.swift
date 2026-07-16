import ClawCore
import Foundation
import Logging

/// The router-facing voice seam: attachment in, transcript-or-typed-failure out. A protocol so
/// routing tests can script outcomes (`.storageFull`, `.timedOut`) that the concrete service only
/// produces under real filesystem/engine conditions.
public protocol VoiceMessageTranscribing: Sendable {
  func transcribe(_ attachment: VoiceAttachment) async -> Result<
    String, VoiceMessageService.Failure
  >
}

/// Turns a Telegram voice attachment into transcript text: guard the declared size/duration,
/// download the audio, stage it in a private scratch file, transcribe on-device under a hard
/// deadline, then redact and cap the text. Every failure maps to a typed case with its own
/// owner-facing reply; engine detail stays in the logs.
public struct VoiceMessageService: VoiceMessageTranscribing {
  public enum Failure: Error, Sendable, Equatable {
    case tooLong
    case downloadFailed
    case transcriptionUnavailable
    case undecodableAudio
    case transcriptionFailed
    case timedOut
    case emptyTranscript
    /// Disk full while staging — routed to the router's storage-full contract (poller backs off,
    /// cursor does NOT advance), never to a generic "try again".
    case storageFull

    public var ownerReplyText: String {
      switch self {
      case .tooLong:
        return "That voice message is too long for me to transcribe."
      case .downloadFailed:
        return "I couldn't download that voice message. Please try again."
      case .transcriptionUnavailable:
        return "I can't transcribe voice messages on this machine yet."
      case .undecodableAudio:
        return "I couldn't decode that voice message's audio."
      case .transcriptionFailed:
        return "Something went wrong transcribing that voice message. Please try again."
      case .timedOut:
        return "Transcribing that voice message took too long, so I gave up."
      case .emptyTranscript:
        return "I couldn't hear any speech in that voice message."
      case .storageFull:
        return Degradation.storageFull
      }
    }
  }

  public static let stagingDirectoryName = "voice-scratch"
  public static let defaultMaxDurationSeconds = 600

  /// Boot sweep: deletes every staged file left by a crash mid-transcription. Derives the
  /// directory from the same constant `stage` writes under, so the swept path can never drift
  /// from the staged path. Flag-independent — raw (possibly third-party) audio must not outlive
  /// a restart even when transcription is currently disabled.
  public static func sweepStaging(under stateRoot: URL) {
    let staging = stateRoot.appending(path: stagingDirectoryName, directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: staging)
  }

  private let fetcher: any VoiceMediaFetching
  private let transcriber: any VoiceTranscribing
  private let stagingDirectory: URL
  private let redactor: SecretRedactor
  private let maxDownloadBytes: Int
  private let maxDurationSeconds: Int
  private let maxTranscriptCharacters: Int
  private let transcriptionDeadline: Duration
  private let logger: Logger

  public init(
    fetcher: any VoiceMediaFetching,
    transcriber: any VoiceTranscribing,
    stagingDirectory: URL,
    redactor: SecretRedactor,
    maxDownloadBytes: Int = 16 * 1024 * 1024,
    maxDurationSeconds: Int = VoiceMessageService.defaultMaxDurationSeconds,
    maxTranscriptCharacters: Int = 20_000,
    transcriptionDeadline: Duration = .seconds(120),
    logger: Logger
  ) {
    self.fetcher = fetcher
    self.transcriber = transcriber
    self.stagingDirectory = stagingDirectory
    self.redactor = redactor
    self.maxDownloadBytes = maxDownloadBytes
    self.maxDurationSeconds = maxDurationSeconds
    self.maxTranscriptCharacters = maxTranscriptCharacters
    self.transcriptionDeadline = transcriptionDeadline
    self.logger = logger
  }

  public func transcribe(_ attachment: VoiceAttachment) async -> Result<String, Failure> {
    // Cheap pre-download refusals on DECLARED metadata only — both values are sender-forgeable
    // on a forwarded note, so the engine re-checks decoded duration and the deadline below is
    // the hard compute bound.
    guard attachment.durationSeconds <= maxDurationSeconds else {
      return .failure(.tooLong)
    }
    if let declaredSize = attachment.fileSizeBytes, declaredSize > Int64(maxDownloadBytes) {
      return .failure(.tooLong)
    }

    let audio: Data
    do {
      audio = try await fetcher.downloadVoiceFile(
        fileId: attachment.fileId,
        maxBytes: maxDownloadBytes
      )
    } catch {
      logger.error("voice download failed: \(error)")
      return .failure(.downloadFailed)
    }

    let staged: URL
    do {
      staged = try stage(audio)
    } catch {
      logger.error("voice staging failed: \(error)")
      return .failure(Self.classifyStagingError(error))
    }
    defer {
      try? FileManager.default.removeItem(at: staged)
    }

    let transcript: String
    switch await transcribeWithDeadline(audioFileAt: staged) {
    case .success(let engineTranscript):
      transcript = engineTranscript
    case .failure(let failure):
      return .failure(failure)
    }

    // Only the transcript SIZE is logged, never its text — same rule as inbound messages.
    logger.info(
      "voice message transcribed (duration=\(attachment.durationSeconds)s chars=\(transcript.count))"
    )
    return normalize(transcript)
  }
}

// MARK: - Deadline

private extension VoiceMessageService {
  /// Races the engine against a wall-clock deadline (the shared ClawCore `DeadlineRace`). This
  /// runs INLINE in the poller loop, so an unbounded engine await (a wedged model-asset
  /// download, a hostile hours-long audio file) would stall all intake — messages, /stop,
  /// approval callbacks. On expiry the engine task is cancelled and abandoned: intake keeps
  /// moving even if the engine ignores cooperative cancellation.
  func transcribeWithDeadline(audioFileAt staged: URL) async -> Result<String, Failure> {
    let transcriber = self.transcriber
    let logger = self.logger
    let outcome = await DeadlineRace.race(allowance: transcriptionDeadline) {
      () async -> Result<String, Failure> in
      do {
        return .success(try await transcriber.transcribe(audioFileAt: staged))
      } catch {
        logger.error("voice transcription failed: \(error)")
        return .failure(Self.mapTranscriptionError(error))
      }
    }

    switch outcome {
    case .operationReturned(let result):
      return result
    case .deadlineExpired:
      logger.error("voice transcription exceeded its \(transcriptionDeadline) deadline")
      return .failure(.timedOut)
    case .callerCancelled:
      // Shutdown, not an engine fault: the reply send that follows is being cancelled too.
      return .failure(.transcriptionFailed)
    }
  }
}

// MARK: - Staging & Normalization

private extension VoiceMessageService {
  /// Writes the audio to a fresh owner-only file in the private staging directory. The caller
  /// deletes it after transcription; a failed write cleans up its own (possibly partial) file
  /// here, because the caller's cleanup only covers a URL that was actually returned —
  /// load-bearing on a full disk, where the storage-full redelivery loop would otherwise
  /// accumulate one orphan per retry. Crash-orphaned files are swept at boot (`sweepStaging`).
  func stage(_ audio: Data) throws -> URL {
    try PrivateDirectory.ensure(at: stagingDirectory)

    let file = stagingDirectory.appendingPathComponent("\(UUID().uuidString).oga")
    do {
      try audio.write(to: file, options: [.withoutOverwriting])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: file.path
      )
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
    return file
  }

  func normalize(_ transcript: String) -> Result<String, Failure> {
    let redacted = redactor.redact(transcript)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !redacted.isEmpty else {
      return .failure(.emptyTranscript)
    }

    return .success(TextTruncation.cap(redacted, maxGraphemes: maxTranscriptCharacters))
  }

  static func mapTranscriptionError(_ error: any Error) -> Failure {
    guard let transcriptionError = error as? VoiceTranscriptionError else {
      return .transcriptionFailed
    }
    switch transcriptionError {
    case .unavailable, .localeUnsupported, .assetsUnavailable:
      return .transcriptionUnavailable
    case .undecodableAudio:
      return .undecodableAudio
    case .audioTooLong:
      return .tooLong
    case .transcriptionFailed, .cancelled:
      return .transcriptionFailed
    }
  }
}

// MARK: - Failure Classification

extension VoiceMessageService {
  /// Disk-full during staging must surface as `.storageFull` so the router honors the project's
  /// storage-full contract instead of replying "try again" and advancing the cursor.
  static func classifyStagingError(_ error: any Error) -> Failure {
    var candidate: NSError? = error as NSError
    while let current = candidate {
      let isCocoaDiskFull =
        current.domain == NSCocoaErrorDomain
        && current.code == CocoaError.fileWriteOutOfSpace.rawValue
      let isPOSIXDiskFull = current.domain == NSPOSIXErrorDomain && current.code == Int(ENOSPC)
      if isCocoaDiskFull || isPOSIXDiskFull {
        return .storageFull
      }
      candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return .transcriptionFailed
  }
}
