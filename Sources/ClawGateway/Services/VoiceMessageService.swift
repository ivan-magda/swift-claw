import ClawCore
import Foundation
import Logging

public protocol VoiceMessageTranscribing: Sendable {
  func transcribe(
    _ attachment: VoiceAttachment
  ) async -> Result<String, VoiceMessageService.Failure>
}

public struct VoiceMessageService: VoiceMessageTranscribing {
  public enum Failure: Error, Sendable, Equatable {
    case tooLong
    case downloadFailed
    case transcriptionUnavailable
    case undecodableAudio
    case transcriptionFailed
    case timedOut
    case emptyTranscript
    case lowConfidence
    case storageFull

    public var ownerReplyText: String {
      switch self {
      case .tooLong:
        "That voice message is too long for me to transcribe."
      case .downloadFailed:
        "I couldn't download that voice message. Please try again."
      case .transcriptionUnavailable:
        "I can't transcribe voice messages on this machine yet."
      case .undecodableAudio:
        "I couldn't decode that voice message's audio."
      case .transcriptionFailed:
        "Something went wrong transcribing that voice message. Please try again."
      case .timedOut:
        "Transcribing that voice message took too long, so I gave up."
      case .emptyTranscript:
        "I couldn't hear any speech in that voice message."
      case .lowConfidence:
        "I couldn't make out that voice message in any of my configured languages."
      case .storageFull:
        Degradation.storageFull
      }
    }
  }

  public static let stagingDirectoryName = "voice-scratch"
  public static let defaultMaxDurationSeconds = 600

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
    guard attachment.durationSeconds <= maxDurationSeconds else {
      return .failure(.tooLong)
    }

    if let declaredSize = attachment.fileSizeBytes,
      declaredSize > Int64(maxDownloadBytes) {
      return .failure(.tooLong)
    }

    let audioData: Data
    do {
      audioData = try await fetcher.downloadVoiceFile(
        fileId: attachment.fileId,
        maxBytes: maxDownloadBytes
      )
    } catch {
      logger.error("voice download failed: \(error)")
      return .failure(.downloadFailed)
    }

    let stagedFileURL: URL
    do {
      stagedFileURL = try stageAudioData(audioData)
    } catch {
      logger.error("voice staging failed: \(error)")
      return .failure(Self.classifyStagingError(error))
    }
    defer {
      try? FileManager.default.removeItem(at: stagedFileURL)
    }

    let transcript: String
    switch await transcribeWithDeadline(audioFileAt: stagedFileURL) {
    case .success(let engineTranscript):
      transcript = engineTranscript
    case .failure(let failure):
      return .failure(failure)
    }

    logger.info(
      "voice message transcribed (duration=\(attachment.durationSeconds)s chars=\(transcript.count))"
    )
    return normalize(transcript)
  }
}

// MARK: - Deadline

private extension VoiceMessageService {
  func transcribeWithDeadline(
    audioFileAt staged: URL
  ) async -> Result<String, Failure> {
    let transcriber = self.transcriber
    let logger = self.logger

    let outcome = await DeadlineRace.race(
      allowance: transcriptionDeadline
    ) { () async -> Result<String, Failure> in
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
      return .failure(.transcriptionFailed)
    }
  }
}

// MARK: - Staging & Normalization

private extension VoiceMessageService {
  func stageAudioData(_ data: Data) throws -> URL {
    try PrivateDirectory.ensure(at: stagingDirectory)

    let file = stagingDirectory.appendingPathComponent("\(UUID().uuidString).oga")
    do {
      try data.write(to: file, options: [.withoutOverwriting])
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
    case .lowConfidence:
      return .lowConfidence
    }
  }
}

// MARK: - Failure Classification

extension VoiceMessageService {
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
