import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationHTTPRecorderTests {
  @Test func wireModelRefusalDoesNotCountAsAnOutboundSend() async throws {
    // given
    let recorder = EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))
    let request = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: Data(#"{"model":"wrong-model"}"#.utf8),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 100, errorBytes: 100)
    )

    // when
    await #expect(throws: EvaluationHTTPError.wireModelMismatch) {
      _ = try await recorder.openStream(request)
    }
    let snapshot = await recorder.snapshot()

    // then
    #expect(snapshot.responsesSends.isEmpty)
    #expect(snapshot.integrityFailures == ["wire_model_mismatch"])
  }

  @Test func responsesInferenceCannotEvadeStreamingAccountingViaBufferedExecute() async {
    // given
    let recorder = EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))
    let request = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: Data(#"{"model":"gpt-5.6-sol"}"#.utf8),
      timeout: .seconds(1),
      responseBodyPolicy: .buffered(successBytes: 1_024, errorBytes: 1_024)
    )

    // when
    await #expect(throws: EvaluationHTTPError.bufferedInferenceForbidden) {
      _ = try await recorder.execute(request)
    }
    let snapshot = await recorder.snapshot()

    // then
    #expect(snapshot.responsesSends.isEmpty)
    #expect(snapshot.credentialHTTPCalls == 0)
    #expect(snapshot.integrityFailures == ["buffered_inference_forbidden"])
  }

  @Test func streamingCannotLeaveTheFrozenResponsesEndpoint() async {
    // given
    let base = ScriptedHTTPExecutor([])
    let recorder = EvaluationHTTPRecorder(base: base)
    let request = HTTPRequest(
      method: .post,
      url: "https://example.invalid/not-responses",
      headers: [:],
      body: Data(#"{"model":"gpt-5.6-sol"}"#.utf8),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 100, errorBytes: 100)
    )

    // when
    let error = await #expect(throws: EvaluationHTTPError.unexpectedStreamEndpoint) {
      _ = try await recorder.openStream(request)
    }
    let snapshot = await recorder.snapshot()

    // then
    #expect(error != nil)
    #expect(snapshot.responsesSends.isEmpty)
    #expect(snapshot.credentialHTTPCalls == 0)
    #expect(snapshot.integrityFailures == ["unexpected_stream_endpoint"])
    #expect(await base.recorded.isEmpty)
  }

  @Test func recorderSeparatesCredentialTrafficAndBindsTheExactFencedCarrierAtItsCap() async throws
  {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "http-progress")
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
      journalName: "http-progress.jsonl"
    )
    let head = HTTPStreamHead(statusCode: 200, headers: [:])
    let http = ScriptedHTTPExecutor([
      .ok(HTTPResult(statusCode: 200, headers: [:], body: Data())),
      .stream(head, []),
      .stream(head, []),
    ])
    let recorder = EvaluationHTTPRecorder(
      base: http,
      maximumResponsesSends: PageEvaluationContract.maximumResponsesSendsPerAttempt,
      progressRecorder: progressFixture.recorder,
      attemptID: configured.configuration.attemptID
    )
    let credential = HTTPRequest(
      method: .post,
      url: "https://auth.openai.com/oauth/token",
      headers: [:],
      body: Data(),
      timeout: .seconds(1),
      responseBodyPolicy: .buffered(successBytes: 1_024, errorBytes: 1_024)
    )
    let carrier = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "active_lessons": ["lesson_set_id": "empty", "lessons": [], "schema_version": 1],
      "schema_version": 1,
      "task": [:],
      "task_id": "page-000000000001",
    ])
    let fenced = LabeledContext(
      label: "file_read",
      content: String(decoding: carrier, as: UTF8.self),
      nonce: String(repeating: "a", count: 32)
    ).render()
    func responsesRequest(input: String) throws -> HTTPRequest {
      HTTPRequest(
        method: .post,
        url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
        headers: [:],
        body: try JSONSerialization.data(withJSONObject: [
          "input": input, "model": PageEvaluationContract.wireModel,
        ]),
        timeout: .seconds(1),
        responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
      )
    }

    // when
    _ = try await recorder.execute(credential)
    _ = try await recorder.openStream(responsesRequest(input: "read input.json"))
    _ = try await recorder.openStream(responsesRequest(input: fenced))
    await #expect(throws: EvaluationHTTPError.responsesSendCap) {
      _ = try await recorder.openStream(responsesRequest(input: fenced))
    }
    let snapshot = await recorder.snapshot()
    let progress = try #require(
      try EvaluationAttemptProgressRecorder.loadIfPresent(
        invocationID: progressFixture.invocation.invocationID,
        invocationConfigurationSHA256: progressFixture.invocation.configurationSHA256,
        configurations: [configured.configuration]
      )
    )

    // then — OAuth is not an inference send, but both credential and safe request metadata are
    // durably forwarded before their respective transport boundaries.
    #expect(snapshot.credentialHTTPCalls == 1)
    #expect(snapshot.responsesSends.map(\.sequence) == [1, 2])
    #expect(snapshot.responsesSends[0].untrustedPayloadSHA256 == nil)
    #expect(snapshot.responsesSends[1].untrustedPayloadSHA256 == SHA256Digest.hex(carrier))
    #expect(snapshot.integrityFailures == ["responses_send_cap"])
    #expect(await http.recorded.count == 3)
    #expect(progress.attempts.first?.credentialHTTPCalls == 1)
    #expect(progress.attempts.first?.responsesRequests == snapshot.responsesSends)
    #expect(progress.attempts.first?.responsesSends == 2)
  }
}
