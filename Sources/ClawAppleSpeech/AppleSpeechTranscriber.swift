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
  /// Apple has no audio language detection and each transcriber module is bound to one locale,
  /// so multi-language support runs the audio through one lane per configured locale and lets
  /// `VoiceTranscriptArbiter` pick the winner by engine confidence. A lane uses the current
  /// `SpeechTranscriber` model where the locale is supported and falls back to
  /// `DictationTranscriber` (the older system-dictation model, e.g. for `ru-RU`) elsewhere.
  ///
  /// An actor for `Sendable` conformance and isolated asset bookkeeping — NOT for job
  /// serialization: a Swift actor is reentrant across `await`, so concurrent `transcribe` calls
  /// would interleave. One-at-a-time execution comes from the caller (the poller handles updates
  /// strictly sequentially); the asset provisioning below is idempotent, so an interleaving from
  /// a future concurrent caller degrades safely rather than corrupting reservation state.
  @available(macOS 26.0, *)
  public actor AppleSpeechTranscriber: VoiceTranscribing {
    private let localeIdentifiers: [String]
    /// Ground-truth duration cap, checked against the DECODED audio: the wire-declared duration
    /// is sender-forgeable, so the engine re-derives it from the file it actually opened.
    private let maxAudioDurationSeconds: Int?

    public init(localeIdentifiers: [String], maxAudioDurationSeconds: Int? = nil) {
      self.localeIdentifiers = localeIdentifiers
      self.maxAudioDurationSeconds = maxAudioDurationSeconds
    }

    public func transcribe(audioFileAt url: URL) async throws(VoiceTranscriptionError) -> String {
      let lanes = await Self.resolveLanes(for: localeIdentifiers)
      guard !lanes.isEmpty else {
        // DictationTranscriber has no `isAvailable`: an empty supported-locale list is its
        // "this host can't run me" signal.
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
      let configuredTags = Set(lanes.map { $0.locale.bcp47Tag })
      var candidates: [ScoredTranscript] = []
      var firstFailure: VoiceTranscriptionError?
      for lane in lanes {
        let scored: ScoredTranscript
        do {
          scored = try await run(lane, configuredTags: configuredTags, url: url)
        } catch {
          if case .cancelled = error {
            throw VoiceTranscriptionError.cancelled
          }
          firstFailure = firstFailure ?? error
          continue
        }
        if (scored.confidence ?? 0) >= VoiceTranscriptArbiter.acceptConfidence {
          return scored.text
        }
        candidates.append(scored)
      }

      switch Self.settle(candidates: candidates, firstFailure: firstFailure) {
      case .success(let transcript):
        return transcript
      case .failure(let failure):
        throw failure
      }
    }

    /// End-of-race policy, pure for testability. A winning candidate beats everything; without
    /// one, a remembered lane failure outranks `.lowConfidence` — the failed lane may be the one
    /// that would have matched, and "couldn't make out the language" would hide the real,
    /// actionable fault.
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

    /// Maps each configured identifier to the engine that actually carries its model, preserving
    /// order. Membership in `supportedLocales` is the gate — `supportedLocale(equivalentTo:)`
    /// only widens a partial tag (`ru` → `ru_RU`) to the engine's spelling and also returns
    /// locales the installed stack cannot transcribe, so its result never counts by itself.
    static func resolveLanes(for identifiers: [String]) async -> [Lane] {
      let speech = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
      let dictation = await DictationTranscriber.supportedLocales

      var lanes: [Lane] = []
      for identifier in identifiers {
        let wanted = Locale(identifier: identifier)
        if let locale = await resolve(
          wanted,
          in: speech,
          via: SpeechTranscriber.supportedLocale(equivalentTo:)
        ) {
          lanes.append(.speech(locale))
        } else if let locale = await resolve(
          wanted,
          in: dictation,
          via: DictationTranscriber.supportedLocale(equivalentTo:)
        ) {
          lanes.append(.dictation(locale))
        }
      }
      return lanes
    }

    static func resolve(
      _ wanted: Locale,
      in supported: [Locale],
      via equivalent: (Locale) async -> Locale?
    ) async -> Locale? {
      if let exact = supported.first(where: { $0.bcp47Tag == wanted.bcp47Tag }) {
        return exact
      }
      guard let normalized = await equivalent(wanted) else {
        return nil
      }
      return supported.first { $0.bcp47Tag == normalized.bcp47Tag }
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

    /// Streams one lane's results and folds them into a `ScoredTranscript`. The file is opened
    /// fresh per lane — an `AVAudioFile` carries a read position, so a shared instance would
    /// feed silence to every lane after the first.
    func analyze<Result: SpeechModuleResult>(
      module: some SpeechModule,
      results: some AsyncSequence<Result, any Error>,
      url: URL
    ) async throws(VoiceTranscriptionError) -> ScoredTranscript {
      do {
        let audioFile = try AVAudioFile(forReading: url)
        // The daemon transcribes repeatedly in one process: keep the speech model loaded across
        // sessions instead of the default load/unload per message. The owner is actively waiting
        // on the reply, so the analysis runs user-initiated rather than background-throttled.
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
            if let value = textRun[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
              confidences.append(value)
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
      if let speech = result as? SpeechTranscriber.Result {
        return speech.isFinal ? speech.text : nil
      }
      if let dictation = result as? DictationTranscriber.Result {
        return dictation.isFinal ? dictation.text : nil
      }
      return nil
    }
  }

  // MARK: - Asset Provisioning

  @available(macOS 26.0, *)
  private extension AppleSpeechTranscriber {
    /// Reserves the lane's locale (releasing only reservations for locales that are no longer
    /// configured — the slot pool is small and other configured lanes must keep theirs) and runs
    /// the installation request unconditionally: a non-nil request with assets already on disk
    /// is per-process reservation bookkeeping whose `downloadAndInstall` is an offline-safe
    /// no-op, so idempotent calls are the reliable path.
    func ensureAssets(
      for module: some SpeechModule,
      locale: Locale,
      configuredTags: Set<String>
    ) async throws(VoiceTranscriptionError) {
      do {
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.bcp47Tag == locale.bcp47Tag }) {
          for stale in reserved where !configuredTags.contains(stale.bcp47Tag) {
            await AssetInventory.release(reservedLocale: stale)
          }
          do {
            try await AssetInventory.reserve(locale: locale)
          } catch {
            // The pool can hold fewer slots than the configured list (maximumReservedLocales is
            // device-dependent): evict one other configured reservation and retry once, so an
            // over-cap lane still runs instead of silently starving on every message.
            let occupied = await AssetInventory.reservedLocales
            guard let evictable = occupied.first(where: { $0.bcp47Tag != locale.bcp47Tag }) else {
              throw error
            }
            await AssetInventory.release(reservedLocale: evictable)
            try await AssetInventory.reserve(locale: locale)
          }
        }

        let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        guard let request else {
          return
        }
        try await request.downloadAndInstall()
      } catch is CancellationError {
        throw VoiceTranscriptionError.cancelled
      } catch {
        throw VoiceTranscriptionError.assetsUnavailable("\(error)")
      }
    }
  }

  // MARK: - Locale Identity

  extension Locale {
    /// Canonical comparison key: reservation, support-list, and configured locales spell the
    /// same language as `ru_RU`, `ru-RU`, or richer variants depending on who created them.
    fileprivate var bcp47Tag: String {
      identifier(.bcp47).lowercased()
    }
  }
#endif

/// Composition-root factory: the Apple transcriber where the host can run it, nil elsewhere
/// (Linux, macOS < 26) so the caller falls back to the canned "can't read voice messages" reply.
/// Hardware/asset eligibility is deliberately NOT probed here — it is a per-call runtime check in
/// `transcribe`, so a mid-lifetime change degrades to a typed error instead of a stale boot state.
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
