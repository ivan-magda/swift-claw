import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationAttemptRunnerIntegrityTests {
  @Test func learningFenceIntegrityRequiresSeparateLessonAndFileReadDigests() async throws {
    // given
    let cases = [
      (name: "verified", fileReadUsesLesson: false),
      (name: "mismatched-file-read", fileReadUsesLesson: true),
    ]

    for item in cases {
      let fixture = try makeLearningAttemptFixture(lessons: ["Preserve semantic page changes."])
      defer { fixture.remove() }
      let carrierPath = try #require(fixture.configuration.carrierPath)
      let carrierData = try EvaluationPathSecurity.readRegularSingleLinkFile(
        at: URL(fileURLWithPath: carrierPath)
      )
      let carrierText = try #require(String(data: carrierData, encoding: .utf8))
      let lessonFence = LabeledContext(
        label: "scheduled_learning_lessons",
        content: fixture.lessonSetText,
        nonce: String(repeating: "a", count: 32)
      ).render()
      let fileReadFence = LabeledContext(
        label: "file_read",
        content: item.fileReadUsesLesson ? fixture.lessonSetText : carrierText,
        nonce: String(repeating: "b", count: 32)
      ).render()
      let recorder = EvaluationHTTPRecorder(
        base: ScriptedHTTPExecutor([
          .stream(HTTPStreamHead(statusCode: 200, headers: [:]), []),
          .stream(HTTPStreamHead(statusCode: 200, headers: [:]), []),
        ])
      )
      _ = try await recorder.openStream(try learningRequest(input: lessonFence))
      _ = try await recorder.openStream(
        try learningRequest(input: "\(lessonFence)\n\n\(fileReadFence)")
      )
      let provider = SequenceProvider(scriptedTwoRoundResponses())
      let roster = ProviderRoster(
        primary: LLMRouteBinding(
          provider: provider,
          wireModel: PageEvaluationContract.wireModel,
          configuredReference: PageEvaluationContract.providerReference,
          costPolicy: .includedPlan,
          reservationPolicy: .chatGPTReplayState
        )
      )

      // when
      let result = try await EvaluationAttemptRunner(
        roster: roster,
        httpRecorder: recorder
      ).run(
        configuration: fixture.configuration,
        sendBudget: EvaluationSendBudgetSnapshot(
          stageAccountedTokens: 0,
          globalAccountedTokens: 0,
          stageResponsesSends: 0,
          globalResponsesSends: 0,
          stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
          stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
        )
      )

      // then — accepting the legacy first-match payload for both labels makes the mismatch pass;
      // rejecting every M3 result makes the verified case fail.
      if item.fileReadUsesLesson {
        #expect(result.learningCarrierVerified == false, Comment(rawValue: item.name))
        #expect(result.outcome == .harnessFailure, Comment(rawValue: item.name))
        #expect(
          result.criticalCode == "untrusted_payload_digest_mismatch",
          Comment(rawValue: item.name)
        )
      } else {
        #expect(
          result.learningCarrierSHA256 == fixture.configuration.inputSHA256,
          Comment(rawValue: item.name)
        )
        #expect(
          result.learningLessonSetSHA256 == fixture.configuration.lessonSetDigest,
          Comment(rawValue: item.name)
        )
        #expect(result.learningInitialTainted == true, Comment(rawValue: item.name))
        #expect(result.learningCarrierVerified == true, Comment(rawValue: item.name))
        #expect(result.outcome == .completed, Comment(rawValue: item.name))
      }
    }
  }

  @Test func toolDeviationTakesPrecedenceOverACompetingCarrierDigestMismatch() async throws {
    // given — the model proposes a forbidden path while the recorded second request also carries
    // the wrong fenced payload. The model-visible task deviation must not become a harness defect.
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let provider = SequenceProvider(scriptedTwoRoundResponses(requestedPath: "other.json"))
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let head = HTTPStreamHead(statusCode: 200, headers: [:])
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([.stream(head, []), .stream(head, [])])
    )
    let wrongCarrier = LabeledContext(
      label: "file_read",
      content: #"{"schema_version":1,"wrong":true}"#,
      nonce: String(repeating: "a", count: 32)
    ).render()
    func request(input: String) throws -> HTTPRequest {
      HTTPRequest(
        method: .post,
        url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
        headers: [:],
        body: try JSONSerialization.data(withJSONObject: [
          "input": input,
          "model": PageEvaluationContract.wireModel,
        ]),
        timeout: .seconds(1),
        responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
      )
    }
    _ = try await recorder.openStream(request(input: "read the approved input"))
    _ = try await recorder.openStream(request(input: wrongCarrier))

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder
    ).run(
      configuration: configured.configuration,
      sendBudget: EvaluationSendBudgetSnapshot(
        stageAccountedTokens: 0,
        globalAccountedTokens: 0,
        stageResponsesSends: 0,
        globalResponsesSends: 0,
        stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
        stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
      )
    )

    // then — mutant: digest-first classification would return harnessFailure and hide the tool
    // safety signal from the scorer.
    #expect(result.outcome == .toolContractFailure)
    #expect(result.criticalCode == "unexpected_file_read_path")
    #expect(result.replacementDisposition == .ineligible)
  }

  @Test func observedToolDeviationCannotBecomeReplacementEligibleAfterAProviderFailure()
    async throws
  {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let firstRound = try #require(
      scriptedTwoRoundResponses(requestedPath: "other.json").first
    )
    let provider = SequenceProvider(
      [firstRound],
      then: ProviderError.partialStreamWithoutCompletedTerminal
    )
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([.stream(HTTPStreamHead(statusCode: 200, headers: [:]), [])])
    )
    let firstRequest = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: [
        "input": "read the approved input",
        "model": PageEvaluationContract.wireModel,
      ]),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
    )
    _ = try await recorder.openStream(firstRequest)

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder
    ).run(
      configuration: configured.configuration,
      sendBudget: EvaluationSendBudgetSnapshot(
        stageAccountedTokens: 0,
        globalAccountedTokens: 0,
        stageResponsesSends: 0,
        globalResponsesSends: 0,
        stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
        stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
      )
    )

    // then — deferring an observed wrong-path tool until a second send lets the competing
    // transport failure spend the one whole-attempt replacement.
    #expect(result.outcome == .toolContractFailure)
    #expect(result.criticalCode == EvaluationToolViolation.unexpectedFileReadPath.rawValue)
    #expect(result.replacementDisposition == .ineligible)
  }

  @Test func liveIntegrityMutationBetweenRoundsStopsBeforeTheSecondProviderSend() async throws {
    // given — the first response requests the sole file read; the live binding then changes.
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let budget = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
      stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
    )
    let progressFixture = try startEvaluationAttemptProgress(
      configuration: configured.configuration,
      configurationURL: configured.configurationURL,
      freezeInputs: frozen.inputs,
      budget: budget,
      journalName: "live-integrity-progress.jsonl"
    )
    let provider = SequenceProvider(scriptedTwoRoundResponses())
    let changedApproval = evaluationContextChangingApprovalBody(frozen.context)
    let freezeVerifier = SequencedEvaluationFreezeVerifier(
      liveContexts: [frozen.context, changedApproval],
      localContext: frozen.context
    )
    let admission = EvaluationLiveFreezeAdmission(
      verifier: freezeVerifier,
      inputs: frozen.inputs,
      initial: frozen.context
    )
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([
        .stream(HTTPStreamHead(statusCode: 200, headers: [:]), [])
      ]),
      progressRecorder: progressFixture.recorder,
      attemptID: configured.configuration.attemptID
    )
    let request = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: [
        "input": "read the approved input",
        "model": PageEvaluationContract.wireModel,
      ]),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
    )
    _ = try await recorder.openStream(request)

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder,
      progressRecorder: progressFixture.recorder
    ).run(
      configuration: configured.configuration,
      sendBudget: budget,
      integrityAdmission: { await admission.evaluate() }
    )
    let progress = try #require(
      try EvaluationAttemptProgressRecorder.loadIfPresent(
        invocationID: progressFixture.invocation.invocationID,
        invocationConfigurationSHA256: progressFixture.invocation.configurationSHA256,
        configurations: [configured.configuration]
      )
    )

    // then — checking only once at worker startup would make provider call 2 happen; deleting the
    // runner's durable usage or tool forwarding loses the completed first-round evidence.
    #expect(await provider.requests.count == 1)
    #expect(result.outcome == .harnessFailure)
    #expect(result.criticalCode == "evaluation-freeze-integrity")
    #expect(result.audit.isEmpty == false)
    #expect(progress.attempts.first?.responsesRequests == result.http.responsesSends)
    #expect(progress.attempts.first?.responsesSends == 1)
    #expect(progress.attempts.first?.provenNotStartedResponsesSends == 0)
    #expect(progress.attempts.first?.usage == result.usage)
    #expect(progress.attempts.first?.usage.count == 1)
    #expect(progress.attempts.first?.fileReads == 1)
    #expect(progress.attempts.first?.accountedTokens == 0)
    let persisted = try JSONDecoder().decode(
      EvaluationAttemptResult.self,
      from: EvaluationCanonicalJSON.data(encoding: result)
    )
    #expect(persisted.audit == result.audit)
  }

  @Test func protectedArtifactDriftBetweenRoundsStopsBeforeTheSecondProviderSend() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let sourceURL = URL(fileURLWithPath: configured.configuration.sourceArtifactPath)
    let provider = SequenceProvider(scriptedTwoRoundResponses())
    let verifier = SequencedEvaluationFreezeVerifier(
      liveContexts: [frozen.context, frozen.context],
      localContext: frozen.context,
      beforeReturningLiveContext: { refreshIndex in
        guard refreshIndex == 1 else {
          return
        }
        try Data("changed during live verification".utf8).write(to: sourceURL)
      }
    )
    let admission = EvaluationLiveFreezeAdmission(
      verifier: verifier,
      inputs: frozen.inputs,
      initial: frozen.context
    )
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let recorder = EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder
    ).run(
      configuration: configured.configuration,
      sendBudget: EvaluationSendBudgetSnapshot(
        stageAccountedTokens: 0,
        globalAccountedTokens: 0,
        stageResponsesSends: 0,
        globalResponsesSends: 0,
        stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
        stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
      ),
      integrityAdmission: { await admission.evaluate() }
    )

    // then — deleting the full-closure refresh check allows provider request 2.
    #expect(await provider.requests.count == 1)
    #expect(result.outcome == .harnessFailure)
    #expect(result.criticalCode == "evaluation-freeze-integrity")
  }

  @Test func preInferenceNoStartSendCountsTowardTheCapWithoutAProxyDebit() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "no-start-accounting")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let budget = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
      stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
    )
    let progressFixture = try startEvaluationAttemptProgress(
      configuration: configured.configuration,
      configurationURL: configured.configurationURL,
      freezeInputs: frozen.inputs,
      budget: budget,
      journalName: "no-start-accounting.jsonl"
    )
    let provider = FailingStreamingProvider(
      cause: .terminal(status: 401, message: "clean pre-inference rejection"),
      accounting: .notStarted
    )
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([
        .stream(HTTPStreamHead(statusCode: 401, headers: [:]), [])
      ]),
      progressRecorder: progressFixture.recorder,
      attemptID: configured.configuration.attemptID
    )
    let request = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: [
        "input": "read the approved input",
        "model": PageEvaluationContract.wireModel,
      ]),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
    )
    _ = try await recorder.openStream(request)

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder,
      progressRecorder: progressFixture.recorder
    ).run(
      configuration: configured.configuration,
      sendBudget: budget
    )
    let noStartProgress = try #require(
      try EvaluationAttemptProgressRecorder.loadIfPresent(
        invocationID: progressFixture.invocation.invocationID,
        invocationConfigurationSHA256: progressFixture.invocation.configurationSHA256,
        configurations: [configured.configuration]
      )
    )

    // then — a typed no-start rejection consumes the send cap but never the missing-usage proxy.
    #expect(await provider.streamCalls == 1)
    #expect(result.http.responsesSends.count == 1)
    #expect(result.http.provenNotStartedResponsesSends == 1)
    #expect(result.usage.isEmpty)
    #expect(result.accountedTokens == 0)
    #expect(noStartProgress.attempts.first?.responsesSends == 1)
    #expect(noStartProgress.attempts.first?.responsesRequests == result.http.responsesSends)
    #expect(noStartProgress.attempts.first?.provenNotStartedResponsesSends == 1)
    #expect(noStartProgress.attempts.first?.usage.isEmpty == true)
    #expect(noStartProgress.attempts.first?.accountedTokens == 0)
  }
}

private func learningRequest(input: String) throws -> HTTPRequest {
  HTTPRequest(
    method: .post,
    url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
    headers: [:],
    body: try JSONSerialization.data(withJSONObject: [
      "input": input,
      "model": PageEvaluationContract.wireModel,
    ]),
    timeout: .seconds(1),
    responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
  )
}
