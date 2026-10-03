import ClawCore
import Foundation

#if canImport(Speech) && canImport(AVFAudio)
  import AVFAudio
  import Speech

  /// On-device file transcription via the macOS 26 `SpeechAnalyzer` stack.
  ///
  /// Apple has no audio language detection and each transcriber module is bound to one locale,
  /// so multi-language support runs the audio through one lane per configured locale and lets
  /// `VoiceTranscriptArbiter` pick the winner by engine confidence. A lane uses the current
  /// `SpeechTranscriber` model where the locale is supported and falls back to
  /// `DictationTranscriber` (the older system-dictation model, e.g. for `ru-RU`) elsewhere.
  @available(macOS 26.0, *)
  actor AppleSpeechTranscriber: VoiceTranscribing {
    private let localeIdentifiers: [String]

    private let maxAudioDurationSeconds: Int?

    init(localeIdentifiers: [String], maxAudioDurationSeconds: Int? = nil) {
      self.localeIdentifiers = localeIdentifiers
      self.maxAudioDurationSeconds = maxAudioDurationSeconds
    }

    func transcribe(audioFileAt url: URL) async throws(VoiceTranscriptionError) -> String {
      let lanes = await Self.resolveLanes(for: localeIdentifiers)

      if lanes.isEmpty {
        let dictationLocales = await DictationTranscriber.supportedLocales

        guard SpeechTranscriber.isAvailable || !dictationLocales.isEmpty else {
          throw VoiceTranscriptionError.unavailable
        }

        throw VoiceTranscriptionError.localeUnsupported(localeIdentifiers.joined(separator: ","))
      }

      let probeFile: AVAudioFile
      do {
        probeFile = try AVAudioFile(forReading: url)
      } catch {
        throw VoiceTranscriptionError.undecodableAudio("\(error)")
      }
      try Self.enforceDecodedDuration(of: probeFile, capSeconds: maxAudioDurationSeconds)

      // Lanes run in configured priority order; a clear early match skips the remaining lanes,
      // and one lane's engine failure must not take down a language that still works.
      let configuredTags = Set(
        lanes.map {
          $0.locale.bcp47Tag
        }
      )
      var candidates: [ScoredTranscript] = []
      var firstFailure: VoiceTranscriptionError?

      for lane in lanes {
        let transcript: ScoredTranscript
        do {
          transcript = try await run(lane, configuredTags: configuredTags, url: url)
        } catch {
          if case .cancelled = error {
            throw VoiceTranscriptionError.cancelled
          }
          firstFailure = firstFailure ?? error
          continue
        }

        if (transcript.confidence ?? 0) >= VoiceTranscriptArbiter.acceptConfidence {
          return transcript.text
        }

        candidates.append(transcript)
      }

      switch Self.settle(candidates: candidates, firstFailure: firstFailure) {
      case .success(let transcript):
        return transcript
      case .failure(let failure):
        throw failure
      }
    }

    static func settle(
      candidates: [ScoredTranscript],
      firstFailure: VoiceTranscriptionError?
    ) -> Result<String, VoiceTranscriptionError> {
      if let winner = VoiceTranscriptArbiter.winner(among: candidates) {
        return .success(winner.text)
      }

      if let firstFailure {
        return .failure(firstFailure)
      }

      guard !candidates.isEmpty else {
        return .failure(.transcriptionFailed("no lane ran"))
      }

      return .failure(.lowConfidence)
    }
  }

  // MARK: - Ground-Truth Duration

  @available(macOS 26.0, *)
  extension AppleSpeechTranscriber {
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

  // MARK: - Lane Resolution

  @available(macOS 26.0, *)
  private extension AppleSpeechTranscriber {
    enum Lane {
      case speech(Locale)
      case dictation(Locale)

      var locale: Locale {
        switch self {
        case .speech(let locale), .dictation(let locale):
          return locale
        }
      }
    }

    static func resolveLanes(for identifiers: [String]) async -> [Lane] {
      let speechLocales: [Locale] =
        if SpeechTranscriber.isAvailable {
          await SpeechTranscriber.supportedLocales
        } else {
          []
        }
      let dictationLocales = await DictationTranscriber.supportedLocales

      var lanes: [Lane] = []
      for identifier in identifiers {
        let requestedLocale = Locale(identifier: identifier)

        let speechLocale = await resolve(
          requestedLocale,
          in: speechLocales,
          via: SpeechTranscriber.supportedLocale(equivalentTo:)
        )
        if let speechLocale {
          lanes.append(.speech(speechLocale))
          continue
        }

        let dictationLocale = await resolve(
          requestedLocale,
          in: dictationLocales,
          via: DictationTranscriber.supportedLocale(equivalentTo:)
        )
        if let dictationLocale {
          lanes.append(.dictation(dictationLocale))
        }
      }

      return lanes
    }

    static func resolve(
      _ requestedLocale: Locale,
      in supportedLocales: [Locale],
      via equivalent: (_ locale: Locale) async -> Locale?
    ) async -> Locale? {
      let requestedTag = requestedLocale.bcp47Tag
      let exactMatch = supportedLocales.first {
        $0.bcp47Tag == requestedTag
      }
      if let exactMatch {
        return exactMatch
      }

      let normalized = await equivalent(requestedLocale)
      guard let normalized else {
        return nil
      }

      return supportedLocales.first {
        $0.bcp47Tag == normalized.bcp47Tag
      }
    }
  }

  // MARK: - Lane Execution

  @available(macOS 26.0, *)
  private extension AppleSpeechTranscriber {
    func run(
      _ lane: Lane,
      configuredTags: Set<String>,
      url: URL
    ) async throws(VoiceTranscriptionError) -> ScoredTranscript {
      switch lane {
      case .speech(let locale):
        let transcriber = SpeechTranscriber(
          locale: locale,
          transcriptionOptions: [],
          reportingOptions: [],
          attributeOptions: [.transcriptionConfidence]
        )
        try await ensureAssets(for: transcriber, locale: locale, configuredTags: configuredTags)
        return try await analyze(module: transcriber, results: transcriber.results, url: url)
      case .dictation(let locale):
        let transcriber = DictationTranscriber(
          locale: locale,
          contentHints: [],
          transcriptionOptions: [],
          reportingOptions: [],
          attributeOptions: [.transcriptionConfidence]
        )
        try await ensureAssets(for: transcriber, locale: locale, configuredTags: configuredTags)
        return try await analyze(module: transcriber, results: transcriber.results, url: url)
      }
    }

    func analyze<Result: SpeechModuleResult>(
      module: some SpeechModule,
      results: some AsyncSequence<Result, any Error>,
      url: URL
    ) async throws(VoiceTranscriptionError) -> ScoredTranscript {
      do {
        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(
          modules: [module],
          options: SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .processLifetime
          )
        )
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var transcript = ""
        var confidences: [Double] = []

        for try await result in results {
          guard let text = Self.finalText(of: result) else {
            continue
          }

          transcript += String(text.characters)

          for textRun in text.runs {
            if let confidence = textRun[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
              confidences.append(confidence)
            }
          }
        }

        return ScoredTranscript(
          text: transcript,
          confidence: VoiceTranscriptArbiter.averageConfidence(confidences)
        )
      } catch is CancellationError {
        throw VoiceTranscriptionError.cancelled
      } catch {
        throw VoiceTranscriptionError.transcriptionFailed("\(error)")
      }
    }

    static func finalText(of result: some SpeechModuleResult) -> AttributedString? {
      if let speechResult = result as? SpeechTranscriber.Result {
        return speechResult.isFinal ? speechResult.text : nil
      }

      if let dictationResult = result as? DictationTranscriber.Result {
        return dictationResult.isFinal ? dictationResult.text : nil
      }

      return nil
    }
  }

  // MARK: - Asset Provisioning

  @available(macOS 26.0, *)
  private extension AppleSpeechTranscriber {
    func ensureAssets(
      for module: some SpeechModule,
      locale: Locale,
      configuredTags: Set<String>
    ) async throws(VoiceTranscriptionError) {
      do {
        let reservedLocales = await AssetInventory.reservedLocales
        let isLocaleReserved = reservedLocales.contains {
          $0.bcp47Tag == locale.bcp47Tag
        }
        if !isLocaleReserved {
          for staleLocale in reservedLocales where !configuredTags.contains(staleLocale.bcp47Tag) {
            await AssetInventory.release(reservedLocale: staleLocale)
          }

          do {
            try await AssetInventory.reserve(locale: locale)
          } catch {
            let occupiedLocales = await AssetInventory.reservedLocales
            let evictableLocale = occupiedLocales.first {
              $0.bcp47Tag != locale.bcp47Tag
            }
            guard let evictableLocale else {
              throw error
            }

            await AssetInventory.release(reservedLocale: evictableLocale)

            try await AssetInventory.reserve(locale: locale)
          }
        }

        let installationRequest = try await AssetInventory.assetInstallationRequest(
          supporting: [module]
        )
        guard let installationRequest else {
          return
        }

        try await installationRequest.downloadAndInstall()
      } catch is CancellationError {
        throw VoiceTranscriptionError.cancelled
      } catch {
        throw VoiceTranscriptionError.assetsUnavailable("\(error)")
      }
    }
  }

  // MARK: - Locale Identity

  extension Locale {
    fileprivate var bcp47Tag: String {
      identifier(.bcp47).lowercased()
    }
  }
#endif

public enum SystemVoiceTranscriber {
  public static func make(
    localeIdentifiers: [String],
    maxAudioDurationSeconds: Int? = nil
  ) -> (any VoiceTranscribing)? {
    #if canImport(Speech) && canImport(AVFAudio)
      guard #available(macOS 26.0, *) else {
        return nil
      }

      return AppleSpeechTranscriber(
        localeIdentifiers: localeIdentifiers,
        maxAudioDurationSeconds: maxAudioDurationSeconds
      )
    #else
      return nil
    #endif
  }
}
