import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite
struct JournalSummarizerTests {
  @Test
  func shortConfirmationAndRussianTailFit() async throws {
    // given
    let secret = "private-secret-value"
    let conclusion = "Итог: выбираем PostgreSQL ради транзакций."
    let sources = try (1...10).map { index in
      try source(
        id: index,
        owner: index == 10 ? "Да, выбираем его." : String(repeating: "вопрос ", count: 560),
        answer: String(repeating: "обсуждение ", count: 710) + secret + conclusion,
        proposal: try JournalProposal(sourceID: "message:1", text: "Выбираем PostgreSQL?"),
        evidence: [try JournalEvidence(outcome: .tool(.ok), name: "file_write")]
      )
    }
    let provider = SequenceProvider([response("{\"notes\":[]}")])
    let binding = binding(provider)
    let budget = budget(input: 20_000, output: 700)
    let codec = JournalSummaryCodec(
      costResolver: resolver,
      redact: SecretRedactor(secretValues: [secret]).redact
    )

    // when
    let prepared = try codec.prepare(sources: sources, binding: binding, budget: budget)
    _ = await JournalSummarizer(codec: codec, clock: ContinuousClock())
      .summarize(prepared, binding: binding, callID: UUIDProviderCallIDGenerator().next())

    // then
    let requests = await provider.requests
    let request = try #require(requests.first)
    let text = request.messages.map(\.content.text).joined(separator: "\n")
    #expect(requests.count == 1)
    #expect(prepared.sources.map(\.id) == sources.map(\.id))
    #expect(request.tools.isEmpty)
    #expect(request.maxOutputTokens == min(JournalLimits.outputTokens, budget.maxOutputTokens))
    #expect(TokenEstimator.estimateInputTokens(request.messages) <= budget.maxInputTokens)
    #expect(try codec.serializedRequest(request).count <= JournalLimits.requestBytes)
    #expect(text.contains(conclusion))
    #expect(text.contains(secret) == false)
    #expect(
      text.contains(
        JournalSummaryCodec.omissionMarker.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    )
    #expect(text.contains("Выбираем PostgreSQL?") == false)
  }

  @Test(arguments: [
    "{\"notes\":[]}",
    "not json",
  ])
  func invalidAndEmptySummariesRemainSinglePaidCalls(content: String) async throws {
    // given
    let provider = SequenceProvider([response(content)])
    let binding = binding(provider)
    let codec = JournalSummaryCodec(
      costResolver: resolver,
      redact: {
        $0
      }
    )
    let prepared = try codec.prepare(sources: [source()], binding: binding, budget: .default)
    let callID = UUIDProviderCallIDGenerator().next()

    // when
    let result = await JournalSummarizer(codec: codec, clock: ContinuousClock())
      .summarize(prepared, binding: binding, callID: callID)

    // then
    let usage = try #require(result.usage)
    #expect(usage.providerCallID == callID)
    #expect(usage.runID == nil)
    #expect(usage.sessionID == prepared.sources[0].sessionID)
    #expect(usage.promptTokens == Self.authoritativeUsage.promptTokens)
    #expect(usage.completionTokens == Self.authoritativeUsage.completionTokens)
    #expect(await provider.requests.count == 1)
    if content == "{\"notes\":[]}" {
      #expect(result.outcome == .empty)
    } else {
      #expect(result.outcome == .invalidSummary)
    }
    #expect(result.notes.isEmpty)
  }

  @Test
  func deadlineAccountingKeepsAuthoritativeLateUsageAndConservativeExposure() async throws {
    // given
    let codec = JournalSummaryCodec(
      costResolver: resolver,
      redact: {
        $0
      }
    )
    let providers: [any LLMProvider] = [
      RacedSuccessProvider(response: response("{\"notes\":[]}")),
      HangingInferenceProvider(observing: 900),
      CancellingProvider(),
      SequenceProvider([], then: ProviderError.partialStreamWithoutCompletedTerminal),
      SequenceProvider(
        [],
        then: ProviderFailure(
          cause: .terminal(status: nil, message: "rejected before inference"),
          accounting: .notStarted
        )
      ),
    ]

    // when
    var results: [JournalSummaryResult] = []
    for (index, provider) in providers.enumerated() {
      let binding = binding(provider)
      let prepared = try codec.prepare(
        sources: [source()],
        binding: binding,
        budget: budget(input: 2_000)
      )
      let parkedDeadline = AsyncGate()
      let clock = ScriptedClock { delay in
        #expect(delay == .seconds(JournalLimits.inferenceDeadlineSeconds))
        if index >= 3 {
          await parkedDeadline.wait()
          try Task.checkCancellation()
        }
      }
      let result = await JournalSummarizer(codec: codec, clock: clock)
        .summarize(prepared, binding: binding, callID: UUIDProviderCallIDGenerator().next())
      results.append(result)
    }

    // then
    #expect(
      results.allSatisfy {
        $0.outcome == .failed
      }
    )
    #expect(results[0].usage?.completionTokens == Self.authoritativeUsage.completionTokens)
    #expect(results[0].usage?.isEstimated == false)
    #expect(results[1].usage?.completionTokens == 900)
    #expect(results[1].usage?.isEstimated == true)
    #expect(results[2].usage == nil)
    #expect(results[3].usage?.isEstimated == true)
    #expect(
      results[3].usage?.completionTokens
        == min(JournalLimits.outputTokens, budget(input: 2_000).maxOutputTokens)
    )
    #expect(results[4].usage == nil)
    #expect(results[3].redactedReason == "Journal summary provider failed")
    #expect(results[4].redactedReason == "Journal summary provider failed")
  }

  @Test
  func outputBoundsAndTypedEvidenceAreValidatedBeforeRendering() throws {
    // given
    let secret = "owner-private-secret"
    let codec = JournalSummaryCodec(
      costResolver: resolver,
      redact: SecretRedactor(secretValues: [secret]).redact
    )
    let observed = try source(evidence: [
      JournalEvidence(outcome: .tool(.ok), name: "file_write"),
    ])
    let workerOnly = try source(evidence: [
      JournalEvidence(outcome: .workerReportedChecks, name: "checks"),
    ])
    let note = JournalNote(
      kind: .result,
      attribution: .observedOperation,
      text: "Записан файл. " + secret,
      sourceIDs: [observed.id]
    )
    let json = try encodedNotes([note])

    // when
    let notes = try codec.decode(response: json, sources: [observed])
    let rendered = codec.render(notes: notes, sources: [observed])

    // then
    #expect(rendered.contains(secret) == false)
    #expect(rendered.contains(observed.id))
    #expect(throws: (any Error).self) {
      try codec.decode(response: json, sources: [workerOnly])
    }
    #expect(throws: (any Error).self) {
      try codec.decode(
        response: encodedNotes(Array(repeating: note, count: 21)),
        sources: [observed]
      )
    }
    let longNote = JournalNote(
      kind: .decision,
      attribution: .owner,
      text: String(repeating: "я", count: JournalLimits.noteGraphemes + 1),
      sourceIDs: [observed.id]
    )
    #expect(throws: (any Error).self) {
      try codec.decode(response: encodedNotes([longNote]), sources: [observed])
    }
    let fullNote = JournalNote(
      kind: .decision,
      attribution: .owner,
      text: String(repeating: "я", count: JournalLimits.noteGraphemes),
      sourceIDs: [observed.id]
    )
    #expect(throws: (any Error).self) {
      try codec.decode(
        response: encodedNotes(Array(repeating: fullNote, count: 11)),
        sources: [observed]
      )
    }
  }

  @Test
  func renderedTimeUsesCitedSourcesFrozenZone() throws {
    // given
    let codec = JournalSummaryCodec(
      costResolver: resolver,
      redact: {
        $0
      }
    )
    let first = try source()
    let later = try source(
      id: 2,
      timeZoneID: "America/New_York",
      occurredAt: first.occurredAt.addingTimeInterval(25_200)
    )
    let note = JournalNote(
      kind: .result,
      attribution: .owner,
      text: "Later result",
      sourceIDs: [later.id]
    )

    // when
    let rendered = codec.render(notes: [note], sources: [first, later])

    // then
    #expect(rendered.hasPrefix("- [05:00]"))
  }

  @Test
  func sharedSupportSurvivesFittingWithoutBecomingActivity() async throws {
    // given
    let proposalTail = "Выбираем PostgreSQL ради транзакций?"
    let proposal = try JournalProposal(
      sourceID: "message:99",
      text: String(repeating: "обсуждение ", count: 170) + proposalTail
    )
    let sources = try [2, 3].map { id in
      try source(
        id: id,
        owner: "Да, выбираем его.",
        answer: String(repeating: "результат ", count: 790),
        proposal: proposal
      )
    }
    let note = JournalNote(
      kind: .decision,
      attribution: .owner,
      text: "Выбрали PostgreSQL.",
      sourceIDs: [sources[1].id]
    )
    let provider = SequenceProvider([response(try encodedNotes([note]))])
    let binding = binding(provider)
    let codec = JournalSummaryCodec(
      costResolver: resolver,
      redact: {
        $0
      }
    )

    // when
    let prepared = try codec.prepare(
      sources: sources,
      binding: binding,
      budget: budget(input: 4_000)
    )
    let result = await JournalSummarizer(codec: codec, clock: ContinuousClock())
      .summarize(prepared, binding: binding, callID: UUIDProviderCallIDGenerator().next())
    let request = try #require(await provider.requests.first)
    let data = try #require(request.messages.last?.content.text.data(using: .utf8))
    let records = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let support = try #require(records["supportOnly"] as? [[String: Any]])

    // then
    #expect(result.outcome == .notes)
    #expect(result.notes == [note])
    #expect(support.count == 1)
    #expect((support.first?["text"] as? String)?.contains(proposalTail) == true)
    #expect(
      prepared.sources.contains {
        $0.id == proposal.sourceID
      } == false
    )
    let unsupported = JournalNote(
      kind: .decision,
      attribution: .owner,
      text: "Only proposal",
      sourceIDs: [proposal.sourceID]
    )
    #expect(throws: (any Error).self) {
      try codec.decode(response: encodedNotes([unsupported]), sources: prepared.sources)
    }
  }

  @Test
  func byteHeavyGraphemesFitTheCompleteRequest() throws {
    // given
    let grapheme = "я" + String(repeating: "\u{0301}", count: 4)
    let sources = try (1...10).map { id in
      try source(
        id: id,
        owner: String(repeating: grapheme, count: 4_000),
        answer: String(repeating: grapheme, count: 8_000)
      )
    }
    let codec = JournalSummaryCodec(
      costResolver: resolver,
      redact: {
        $0
      }
    )

    // when
    let prepared = try codec.prepare(
      sources: sources,
      binding: binding(SequenceProvider([])),
      budget: .default
    )

    // then
    #expect(prepared.serializedRequestBytes <= JournalLimits.requestBytes)
    #expect(prepared.estimate.inputTokens <= JournalLimits.inputTokens)
    #expect(prepared.sources.count == JournalLimits.batchSources)
    #expect(
      prepared.sources.allSatisfy {
        $0.assistantText.hasSuffix(grapheme)
      }
    )
  }

  @Test
  func redactionExpansionContinuesToAFittingExcerpt() throws {
    // given
    let secret = "secretx"
    let grapheme = "я" + String(repeating: "\u{0301}", count: 64)
    let source = try source(
      owner: String(repeating: grapheme, count: 990),
      answer: String(repeating: secret, count: 100)
    )
    let codec = JournalSummaryCodec(
      costResolver: resolver,
      redact: SecretRedactor(secretValues: [secret]).redact
    )

    // when
    let prepared = try codec.prepare(
      sources: [source],
      binding: binding(SequenceProvider([])),
      budget: .default
    )

    // then
    #expect(prepared.sources.map(\.id) == [source.id])
    #expect(prepared.sources[0].ownerText.hasSuffix(grapheme))
    #expect(prepared.sources[0].assistantText.contains(secret) == false)
    #expect(prepared.serializedRequestBytes <= JournalLimits.requestBytes)
  }

  @Test
  func usefulWholeSourcesAreDeferredAndImpossibleSourceIsNamed() throws {
    // given
    let codec = JournalSummaryCodec(
      costResolver: resolver,
      redact: {
        $0
      }
    )
    let binding = binding(SequenceProvider([]))
    let sources = try (1...10).map { index in
      try source(
        id: index,
        owner: String(repeating: "я", count: 4_000),
        answer: String(repeating: "ю", count: 8_000)
      )
    }

    // when
    let prepared = try codec.prepare(sources: sources, binding: binding, budget: budget(input: 900))

    // then
    #expect(prepared.sources.isEmpty == false)
    #expect(prepared.sources.count < sources.count)
    #expect(
      prepared.sources.allSatisfy {
        !$0.ownerText.isEmpty && !$0.assistantText.isEmpty
      }
    )
    #expect(throws: JournalSummaryPreparationError.unrepresentableSource(id: sources[0].id)) {
      try codec.prepare(sources: sources, binding: binding, budget: budget(input: 1))
    }
  }

}

// MARK: - Fixtures

private extension JournalSummarizerTests {
  func encodedNotes(_ notes: [JournalNote]) throws -> String {
    struct Output: Encodable {
      let notes: [JournalNote]
    }
    let data = try JSONEncoder().encode(Output(notes: notes))
    return try #require(String(bytes: data, encoding: .utf8))
  }

  static let authoritativeUsage = ChatUsage(
    promptTokens: 123,
    completionTokens: 17,
    totalTokens: 140
  )

  var resolver: CostResolver {
    CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015)
  }

  func response(_ content: String) -> ChatResponse {
    ChatResponse(
      content: content,
      finishReason: "stop",
      usage: Self.authoritativeUsage,
      costFromProvider: 0.01
    )
  }

  func binding(_ provider: any LLMProvider) -> LLMRouteBinding {
    LLMRouteBinding(
      provider: provider,
      wireModel: "test-model",
      configuredReference: "test/test-model",
      costPolicy: .metered,
      reservationPolicy: .textOnly
    )
  }

  func budget(input: Int, output: Int = 500) -> RunBudget {
    RunBudget(
      maxInputTokens: input,
      maxOutputTokens: output,
      wallClockDeadlineSeconds: 180,
      retryBudget: 2,
      perRunUSD: 1,
      perDayUSD: 10,
      proactivePerDayUSD: 1,
      referenceUSDPerToken: 0.000_015
    )
  }

  func source(
    id: Int = 1,
    timeZoneID: String = "Europe/Istanbul",
    occurredAt: Date = Date(timeIntervalSince1970: 1_791_424_800),
    owner: String = "Выбираем PostgreSQL.",
    answer: String = "Выбрали PostgreSQL ради транзакций.",
    proposal: JournalProposal? = nil,
    evidence: [JournalEvidence] = []
  ) throws -> JournalSource {
    let day = try #require(JournalDay(isoDate: "2026-10-08"))
    return try JournalSource(
      id: "message:\(id)",
      scope: JournalScope(ownerUserID: 7, timeZoneID: timeZoneID),
      sessionID: 42,
      occurredAt: occurredAt,
      day: day,
      ownerText: owner,
      assistantText: answer,
      supportingProposal: proposal,
      evidence: evidence
    )
  }
}
