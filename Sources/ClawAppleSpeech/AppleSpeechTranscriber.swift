import ClawCore
import Foundation

#if canImport(Speech) && canImport(AVFAudio)
  import AVFAudio
  import Speech

  /// On-device file transcription via the macOS 26 `SpeechAnalyzer` stack. File-based
  /// transcription needs no authorization, TCC prompt, or app bundle (Apple scopes the
  /// speech-recognition permission flow to the legacy `SFSpeechRecognizer` only), and
  /// `AVAudioFile` decodes Telegram's Ogg/Opus natively — see
  /// docs/research/telegram-voice-transcription-2026-07-16.md.
  ///
  /// An actor for `Sendable` conformance and isolated asset bookkeeping — NOT for job
  /// serialization: a Swift actor is reentrant across `await`, so concurrent `transcribe` calls
  /// would interleave. One-at-a-time execution comes from the caller (the poller handles updates
  /// strictly sequentially); the asset provisioning below is idempotent, so an interleaving from
  /// a future concurrent caller degrades safely rather than corrupting reservation state.
  @available(macOS 26.0, *)
  public actor AppleSpeechTranscriber: VoiceTranscribing {
    private let localeIdentifier: String
    /// Ground-truth duration cap, checked against the DECODED audio: the wire-declared duration
    /// is sender-forgeable, so the engine re-derives it from the file it actually opened.
    private let maxAudioDurationSeconds: Int?

    public init(localeIdentifier: String, maxAudioDurationSeconds: Int? = nil) {
      self.localeIdentifier = localeIdentifier
      self.maxAudioDurationSeconds = maxAudioDurationSeconds
    }

    public func transcribe(audioFileAt url: URL) async throws(VoiceTranscriptionError) -> String {
      guard SpeechTranscriber.isAvailable else {
        throw VoiceTranscriptionError.unavailable
      }
      guard
        let locale = await SpeechTranscriber.supportedLocale(
          equivalentTo: Locale(identifier: localeIdentifier)
        )
      else {
        throw VoiceTranscriptionError.localeUnsupported(localeIdentifier)
      }

      let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: []
      )

      do {
        try await ensureAssets(for: transcriber, locale: locale)
      } catch is CancellationError {
        throw VoiceTranscriptionError.cancelled
      } catch {
        throw VoiceTranscriptionError.assetsUnavailable("\(error)")
      }

      let audioFile: AVAudioFile
      do {
        audioFile = try AVAudioFile(forReading: url)
      } catch {
        throw VoiceTranscriptionError.undecodableAudio("\(error)")
      }

      try Self.enforceDecodedDuration(of: audioFile, capSeconds: maxAudioDurationSeconds)

      do {
        // The daemon transcribes repeatedly in one process: keep the speech model loaded across
        // sessions instead of the default load/unload per message. The owner is actively waiting
        // on the reply, so the analysis runs user-initiated rather than background-throttled.
        let analyzer = SpeechAnalyzer(
          modules: [transcriber],
          options: SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .processLifetime
          )
        )
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var transcript = ""
        for try await result in transcriber.results {
          transcript += String(result.text.characters)
        }
        return transcript
      } catch is CancellationError {
        throw VoiceTranscriptionError.cancelled
      } catch {
        throw VoiceTranscriptionError.transcriptionFailed("\(error)")
      }
    }
  }

  // MARK: - Ground-Truth Duration

  @available(macOS 26.0, *)
  extension AppleSpeechTranscriber {
    /// Pure arithmetic on an already-opened file, separated from the engine so it is testable
    /// without speech assets or network: the wire-declared duration is sender-forgeable, this
    /// value is not.
    static func enforceDecodedDuration(
      of audioFile: AVAudioFile,
      capSeconds: Int?
    ) throws(VoiceTranscriptionError) {
      guard let capSeconds else {
        return
      }
      let decodedSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
      guard decodedSeconds <= Double(capSeconds) else {
        throw VoiceTranscriptionError.audioTooLong(seconds: Int(decodedSeconds))
      }
    }
  }

  // MARK: - Asset Provisioning

  @available(macOS 26.0, *)
  private extension AppleSpeechTranscriber {
    /// Reserves the locale (releasing this process's stale reservations first — the slot pool is
    /// small and the daemon only ever uses one locale) and runs the installation request
    /// unconditionally: a non-nil request with assets already on disk is per-process reservation
    /// bookkeeping whose `downloadAndInstall` is an offline-safe no-op, so idempotent calls are
    /// the reliable path.
    func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
      let reserved = await AssetInventory.reservedLocales
      if !reserved.contains(locale) {
        for stale in reserved {
          await AssetInventory.release(reservedLocale: stale)
        }
        try await AssetInventory.reserve(locale: locale)
      }

      let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
      guard let request else {
        return
      }
      try await request.downloadAndInstall()
    }
  }
#endif

/// Composition-root factory: the Apple transcriber where the host can run it, nil elsewhere
/// (Linux, macOS < 26) so the caller falls back to the canned "can't read voice messages" reply.
/// Hardware/asset eligibility is deliberately NOT probed here — it is a per-call runtime check in
/// `transcribe`, so a mid-lifetime change degrades to a typed error instead of a stale boot state.
public enum SystemVoiceTranscriber {
  public static func make(
    localeIdentifier: String,
    maxAudioDurationSeconds: Int? = nil
  ) -> (any VoiceTranscribing)? {
    #if canImport(Speech) && canImport(AVFAudio)
      guard #available(macOS 26.0, *) else {
        return nil
      }
      return AppleSpeechTranscriber(
        localeIdentifier: localeIdentifier,
        maxAudioDurationSeconds: maxAudioDurationSeconds
      )
    #else
      return nil
    #endif
  }
}
