import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

/// Echoes the STAGED FILE's bytes back as text, proving the download really reached disk intact.
private struct StagedBytesEchoTranscriber: VoiceTranscribing {
  func transcribe(audioFileAt url: URL) async throws(VoiceTranscriptionError) -> String {
    guard
      let data = try? Data(contentsOf: url),
      let text = String(bytes: data, encoding: .utf8)
    else {
      throw VoiceTranscriptionError.undecodableAudio("unreadable staged file")
    }
    return text
  }
}

@Suite struct VoiceMessageServiceTests {
  private let attachment = VoiceAttachment(
    fileId: "F1",
    durationSeconds: 8,
    mimeType: "audio/ogg",
    fileSizeBytes: 4
  )

  private func makeService(
    fetcher: any VoiceMediaFetching = StubVoiceFetcher(),
    transcriber: any VoiceTranscribing,
    stagingDirectory: URL,
    secretValues: [String] = [],
    maxDownloadBytes: Int = 16 * 1024 * 1024,
    maxTranscriptCharacters: Int = 20_000,
    transcriptionDeadline: Duration = .seconds(120)
  ) -> VoiceMessageService {
    VoiceMessageService(
      fetcher: fetcher,
      transcriber: transcriber,
      stagingDirectory: stagingDirectory,
      redactor: SecretRedactor(secretValues: secretValues),
      maxDownloadBytes: maxDownloadBytes,
      maxTranscriptCharacters: maxTranscriptCharacters,
      transcriptionDeadline: transcriptionDeadline,
      logger: TestLog.silent
    )
  }

  @Test func stagesTheDownloadedBytesAndCleansUpAfterItself() async throws {
    // given — distinctive bytes arranged HERE, so the assertion has one visible source
    let staging = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: staging) }
    let service = makeService(
      fetcher: StubVoiceFetcher(audio: Data("staged-bytes".utf8)),
      transcriber: StagedBytesEchoTranscriber(),
      stagingDirectory: staging
    )

    // when
    let result = await service.transcribe(attachment)

    // then — the transcriber saw the exact downloaded bytes, and no staged file remains
    #expect(try result.get() == "staged-bytes")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.path)
    #expect(leftovers.isEmpty)
  }

  @Test func sweepStagingRemovesCrashOrphanedAudio() throws {
    // given — a staged file a crash left behind under the state root
    let stateRoot = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let staging = stateRoot.appendingPathComponent(
      VoiceMessageService.stagingDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let orphan = staging.appendingPathComponent("orphan.oga")
    try Data("raw audio".utf8).write(to: orphan)

    // when
    VoiceMessageService.sweepStaging(under: stateRoot)

    // then
    #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
    #expect(FileManager.default.fileExists(atPath: staging.path) == false)
  }

  @Test func stagedFileIsCleanedUpOnTheFailurePathToo() async throws {
    // given — a transcriber that fails after the audio was staged
    let staging = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: staging) }
    let service = makeService(
      transcriber: StubVoiceTranscriber(result: .failure(.transcriptionFailed("engine"))),
      stagingDirectory: staging
    )

    // when
    let result = await service.transcribe(attachment)

    // then — the failure surfaced AND no raw audio lingers
    #expect(result == .failure(.transcriptionFailed))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.path)
    #expect(leftovers.isEmpty)
  }

  @Test func passesTheConfiguredDownloadCapToTheFetcher() async throws {
    // given — a distinctive cap so a hardcoded constant cannot pass by luck
    let staging = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: staging) }
    let fetcher = StubVoiceFetcher()
    let service = makeService(
      fetcher: fetcher,
      transcriber: StubVoiceTranscriber(),
      stagingDirectory: staging,
      maxDownloadBytes: 12_345
    )

    // when
    _ = await service.transcribe(attachment)

    // then — the bounded-download cap survives the middle of the chain
    let call = try #require(await fetcher.recorder.calls.first)
    #expect(call == StubVoiceFetcher.FetchCall(fileId: "F1", maxBytes: 12_345))
  }

  @Test func redactsSecretsFromTheTranscript() async throws {
    // given — a transcript that happens to speak a configured secret aloud
    let staging = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: staging) }
    let service = makeService(
      transcriber: StubVoiceTranscriber(result: .success("the token is hunter2 okay")),
      stagingDirectory: staging,
      secretValues: ["hunter2"]
    )

    // when
    let result = await service.transcribe(attachment)

    // then
    #expect(try result.get() == "the token is \(SecretRedactor.replacement) okay")
  }

  @Test func capsAnOverlongTranscriptWithTheCanonicalMarker() async throws {
    // given
    let staging = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: staging) }
    let service = makeService(
      transcriber: StubVoiceTranscriber(result: .success(String(repeating: "a", count: 50))),
      stagingDirectory: staging,
      maxTranscriptCharacters: 30
    )

    // when
    let result = await service.transcribe(attachment)

    // then — ToolOutputCap semantics: the marker fits WITHIN the cap
    let transcript = try result.get()
    #expect(
      transcript
        == String(repeating: "a", count: 30 - TextTruncation.marker.count) + TextTruncation.marker
    )
    #expect(transcript.count == 30)
  }

  @Test func whitespaceOnlyTranscriptIsAnEmptyTranscriptFailure() async throws {
    // given
    let staging = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: staging) }
    let service = makeService(
      transcriber: StubVoiceTranscriber(result: .success(" \n\t ")),
      stagingDirectory: staging
    )

    // when
    let result = await service.transcribe(attachment)

    // then
    #expect(result == .failure(.emptyTranscript))
  }

  @Test func lowConfidenceFromTheEngineBecomesItsOwnFailure() async throws {
    // given — every configured locale scored below the arbiter floor
    let staging = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: staging) }
    let service = makeService(
      transcriber: StubVoiceTranscriber(result: .failure(.lowConfidence)),
      stagingDirectory: staging
    )

    // when
    let result = await service.transcribe(attachment)

    // then — distinct from .transcriptionFailed: the owner should adjust languages, not retry
    #expect(result == .failure(.lowConfidence))
  }

  @Test func declaredFileSizeOverTheCapIsRefusedWithoutFetching() async throws {
    // given — Telegram declares a size beyond what we would download
    let oversized = VoiceAttachment(
      fileId: "F1",
      durationSeconds: 8,
      mimeType: "audio/ogg",
      fileSizeBytes: Int64(64 * 1024 * 1024)
    )
    let staging = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: staging) }
    let fetcher = StubVoiceFetcher()
    let service = makeService(
      fetcher: fetcher,
      transcriber: StubVoiceTranscriber(),
      stagingDirectory: staging
    )

    // when
    let result = await service.transcribe(oversized)

    // then — refused before a single byte moves
    #expect(result == .failure(.tooLong))
    #expect(await fetcher.recorder.calls.isEmpty)
  }

  @Test func wedgedTranscriptionHitsTheDeadlineInsteadOfStallingForever() async throws {
    // given — an engine that never returns until cancelled
    let staging = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: staging) }
    let service = makeService(
      transcriber: ParkUntilCancelledTranscriber(),
      stagingDirectory: staging,
      transcriptionDeadline: .milliseconds(50)
    )

    // when
    let result = await service.transcribe(attachment)

    // then — the intake loop gets its thread back with a typed failure
    #expect(result == .failure(.timedOut))
  }

  @Test(arguments: [
    (VoiceTranscriptionError.unavailable, VoiceMessageService.Failure.transcriptionUnavailable),
    (.localeUnsupported("xx-XX"), .transcriptionUnavailable),
    (.assetsUnavailable("offline"), .transcriptionUnavailable),
    (.undecodableAudio("bad header"), .undecodableAudio),
    (.audioTooLong(seconds: 7_200), .tooLong),
    (.transcriptionFailed("engine"), .transcriptionFailed),
    (.cancelled, .transcriptionFailed),
  ])
  func transcriberErrorsMapToTheirOwnerFacingFailures(
    engineError: VoiceTranscriptionError,
    expected: VoiceMessageService.Failure
  ) async throws {
    // given
    let staging = try makeTemporaryRoot(prefix: "voice-service-tests")
    defer { try? FileManager.default.removeItem(at: staging) }
    let service = makeService(
      transcriber: StubVoiceTranscriber(result: .failure(engineError)),
      stagingDirectory: staging
    )

    // when
    let result = await service.transcribe(attachment)

    // then
    #expect(result == .failure(expected))
  }

  @Test func diskFullStagingErrorsClassifyAsStorageFull() {
    // given — the two spellings of ENOSPC plus an unrelated error
    let cocoaDiskFull = CocoaError(.fileWriteOutOfSpace)
    let posixDiskFull = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    let wrapped = NSError(
      domain: NSCocoaErrorDomain,
      code: CocoaError.fileWriteUnknown.rawValue,
      userInfo: [NSUnderlyingErrorKey: posixDiskFull]
    )
    let unrelated = CocoaError(.fileWriteNoPermission)

    // when / then
    #expect(VoiceMessageService.classifyStagingError(cocoaDiskFull) == .storageFull)
    #expect(VoiceMessageService.classifyStagingError(posixDiskFull) == .storageFull)
    #expect(VoiceMessageService.classifyStagingError(wrapped) == .storageFull)
    #expect(VoiceMessageService.classifyStagingError(unrelated) == .transcriptionFailed)
  }
}
