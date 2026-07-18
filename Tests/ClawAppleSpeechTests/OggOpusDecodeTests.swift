import ClawCore
import Foundation
import Testing

@testable import ClawAppleSpeech

#if canImport(AVFAudio)
  import AVFAudio

  /// The pipeline hands Telegram's Ogg/Opus straight to `AVAudioFile` with no transcoder — that
  /// rests on an UNDOCUMENTED CoreAudio component ('Oggf', no public constant), so this fixture
  /// decode is the tripwire for an OS update silently removing it. The fixture is SYNTHETIC
  /// (say → ffmpeg libopus → Ogg, 48 kHz mono — the exact codec/container/params of a real voice
  /// note); swapping in a genuine Telegram `getFile` download is the still-open spike in
  /// docs/research/telegram-voice-transcription-2026-07-16.md §5.2.
  @Suite struct OggOpusDecodeTests {
    private func fixtureURL() throws -> URL {
      try #require(
        Bundle.module.url(forResource: "voice-note", withExtension: "oga", subdirectory: "Fixtures")
      )
    }

    @Test func avAudioFileDecodesTelegramShapedOggOpusToPCM() throws {
      // given
      let fixture = try fixtureURL()

      // when
      let audioFile = try AVAudioFile(forReading: fixture)
      let format = audioFile.processingFormat
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFile.length))
      )
      try audioFile.read(into: buffer)

      // then — real PCM came out (audible samples, mono, Opus's native 48 kHz), not silence
      #expect(buffer.frameLength > 0)
      #expect(format.channelCount == 1)
      #expect(format.sampleRate == 48_000)
      let channel = try #require(buffer.floatChannelData)
      var peak: Float = 0
      for index in 0..<Int(buffer.frameLength) {
        peak = max(peak, abs(channel[0][index]))
      }
      #expect(peak > 0)
    }
  }

  /// The ground-truth duration guard is pure arithmetic on an opened file — testable with the
  /// fixture (~7.8s of audio), no speech assets or network involved.
  @Suite struct DecodedDurationGuardTests {
    @available(macOS 26.0, *)
    @Test func fixtureWithinCapPassesAndOverCapThrowsAudioTooLong() throws {
      // given
      let fixture = try #require(
        Bundle.module.url(forResource: "voice-note", withExtension: "oga", subdirectory: "Fixtures")
      )
      let audioFile = try AVAudioFile(forReading: fixture)

      // when / then — nil and generous caps pass; a cap below the decoded length throws typed
      try AppleSpeechTranscriber.enforceDecodedDuration(of: audioFile, capSeconds: nil)
      try AppleSpeechTranscriber.enforceDecodedDuration(of: audioFile, capSeconds: 600)
      #expect(throws: VoiceTranscriptionError.audioTooLong(seconds: 7)) {
        try AppleSpeechTranscriber.enforceDecodedDuration(of: audioFile, capSeconds: 5)
      }
    }
  }

  /// End-to-end engine test: real `SpeechAnalyzer` transcription of the fixture. Opt-in only
  /// (CLAW_SPEECH_LIVE_TESTS=1): first use may download model assets over the network, which the
  /// deterministic suite must never depend on.
  @Suite(
    .enabled(if: ProcessInfo.processInfo.environment["CLAW_SPEECH_LIVE_TESTS"] == "1")
  )
  struct AppleSpeechTranscriberLiveTests {
    @available(macOS 26.0, *)
    @Test func transcribesTheFixtureVerbatim() async throws {
      // given
      let fixture = try #require(
        Bundle.module.url(forResource: "voice-note", withExtension: "oga", subdirectory: "Fixtures")
      )
      let transcriber = AppleSpeechTranscriber(localeIdentifiers: ["en-US"])

      // when
      let transcript = try await transcriber.transcribe(audioFileAt: fixture)

      // then — the fixture's known ground truth, tolerant of inverse-text-normalization drift
      #expect(transcript.lowercased().contains("quick brown fox"))
    }

    /// Both fixtures run with the WRONG language configured first, so passing requires the full
    /// race: the mismatched lane must score below early-accept and the matching lane must win.
    /// The Russian lane also exercises the `DictationTranscriber` fallback — `ru-RU` has no
    /// `SpeechTranscriber` model.
    @available(macOS 26.0, *)
    @Test(arguments: [
      (fixture: "voice-note", expected: "quick brown fox", locales: ["ru-RU", "en-US"]),
      (fixture: "voice-note-ru", expected: "французских", locales: ["en-US", "ru-RU"]),
      // Language-only tags are valid BCP-47 and must resolve to each engine's regional model.
      (fixture: "voice-note-ru", expected: "французских", locales: ["en", "ru"]),
    ])
    func multiLocaleRacePicksTheLaneMatchingTheAudio(
      _ testCase: (fixture: String, expected: String, locales: [String])
    ) async throws {
      // given
      let fixture = try #require(
        Bundle.module.url(
          forResource: testCase.fixture,
          withExtension: "oga",
          subdirectory: "Fixtures"
        )
      )
      let transcriber = AppleSpeechTranscriber(localeIdentifiers: testCase.locales)

      // when
      let transcript = try await transcriber.transcribe(audioFileAt: fixture)

      // then
      #expect(transcript.lowercased().contains(testCase.expected))
    }
  }
#endif
