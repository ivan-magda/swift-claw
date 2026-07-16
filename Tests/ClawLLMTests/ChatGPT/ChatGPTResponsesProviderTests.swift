import ClawAuth
import ClawCore
import ClawTestSupport
import Foundation
import Logging
import Synchronization
import Testing

@testable import ClawLLM

/// The assembled ChatGPT Responses provider: one fixed endpoint, one allowlisted header set, and one
/// attempt engine that both `complete` and `stream` drive. Every HTTP outcome is scripted at the
/// unmanaged seam and every delay runs on a manual clock, so nothing here waits on real time.
@Suite struct ChatGPTResponsesProviderTests {
  // MARK: - Endpoint and headers

  @Test(.timeLimit(.minutes(1)))
  func everyCallUsesTheFixedEndpointAndTheExactHeaderSet() async throws {
    // given
    let harness = ProviderHarness(steps: [.stream(okHead, Fixtures.basicSuccess())])

    // when
    _ = try await harness.provider.complete(request: sessionedRequest)

    // then — the URL is the pinned constant, and the headers are exactly the adapter-owned set plus
    // the one credential header, with the session pair present because the request carried a session
    let recorded = try #require(await harness.http.recorded.first)
    #expect(recorded.url == "https://chatgpt.com/backend-api/codex/responses")
    #expect(recorded.url == ChatGPTProviderMetadata.responsesURL)
    #expect(
      recorded.headers == [
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "OpenAI-Beta": "responses=experimental",
        "originator": "codex_cli_rs",
        "User-Agent": "codex_cli_rs/0.0.0 (swift-claw/1.2.3-test)",
        "Authorization": "Bearer test-token",
        "session_id": "sess-1",
        "x-client-request-id": "sess-1",
      ]
    )
  }

  @Test(.timeLimit(.minutes(1)))
  func theOptionalAccountHeaderIsAcceptedFromTheCredentialSource() async throws {
    // given — the credential offers the one optional second header
    let credentials = ScriptedLLMCredentialSource(
      headers: ["Authorization": "Bearer test-token", "ChatGPT-Account-ID": "acct-42"],
      redactionValues: ["test-token"]
    )
    let harness = ProviderHarness(
      steps: [.stream(okHead, Fixtures.basicSuccess())],
      credentials: credentials
    )

    // when
    _ = try await harness.provider.complete(request: plainRequest)

    // then — it merges under its canonical spelling and the request dispatches
    let recorded = try #require(await harness.http.recorded.first)
    #expect(recorded.headers["ChatGPT-Account-ID"] == "acct-42")
    #expect(recorded.headers["Authorization"] == "Bearer test-token")
  }

  @Test(.timeLimit(.minutes(1)))
  func aCredentialSourceCannotOverrideAnAdapterHeaderAndIsRejectedBeforeHTTP() async throws {
    // given — a source injecting a wire header, session routing, the beta flag, and unknown names
    let credentials = ScriptedLLMCredentialSource(
      headers: [
        "Authorization": "Bearer test-token",
        "Host": "evil.test",
        "Content-Type": "text/plain",
        "session_id": "hijacked",
        "OpenAI-Beta": "off",
        "User-Agent": "curl/8",
        "X-Injected": "1",
      ],
      redactionValues: ["test-token"]
    )
    let harness = ProviderHarness(
      steps: [.stream(okHead, Fixtures.basicSuccess())],
      credentials: credentials
    )

    // when
    let failure = await requireProviderFailure {
      try await harness.provider.complete(request: plainRequest)
    }

    // then — rejected before any dispatch, and the rejection is the header allowlist's doing
    #expect(await harness.http.recorded.isEmpty)
    #expect(failure.accounting == .notStarted)
    guard case .terminal(_, let message) = failure.cause else {
      Issue.record("expected a terminal refusal, got \(failure.cause)")
      return
    }
    #expect(message.contains("not accepted"))
  }

  @Test(.timeLimit(.minutes(1)))
  func onlyAuthorizationAndAccountAreEverAccepted() async throws {
    // given — a source offering nothing but the bearer, the paired positive to the rejection above
    let harness = ProviderHarness(steps: [.stream(okHead, Fixtures.basicSuccess())])

    // when
    let response = try await harness.provider.complete(request: plainRequest)

    // then — a clean dispatch proves the rejection test fails on the bad headers, not on all headers
    #expect(await harness.http.recorded.count == 1)
    #expect(response.content == "Hello")
  }

  // MARK: - complete / stream parity

  @Test(.timeLimit(.minutes(1)))
  func completeAndStreamProduceIdenticalOutputsOnTheSameSSE() async throws {
    // given — two providers with the identical rich script: text, reasoning, a tool call, and usage
    let completeHarness = ProviderHarness(steps: [.stream(okHead, Fixtures.richSuccess())])
    let streamHarness = ProviderHarness(steps: [.stream(okHead, Fixtures.richSuccess())])

    // when
    let completed = try await completeHarness.provider.complete(request: plainRequest)
    let stream = streamHarness.provider.stream(request: plainRequest)
    let drained = await drain(stream)

    // then — identical terminal reply, usage, tool calls, and replay state
    guard case .completed(let streamed) = drained.terminal else {
      Issue.record("expected a completed stream, got \(drained.terminal)")
      return
    }
    #expect(completed == streamed)
    #expect(completed.content == "Hello")
    #expect(completed.usage == ChatUsage(promptTokens: 5, completionTokens: 2, totalTokens: 7))
    #expect(completed.toolCalls.map(\.name) == ["clock"])
    #expect(completed.providerState != nil)

    // and — the stream publishes the visible delta and exactly one terminal event, then closes
    #expect(drained.events.contains(.delta("Hello")))
    let finishes = drained.events.filter { event in
      if case .finished = event { return true }
      return false
    }
    #expect(finishes.count == 1)
    #expect(drained.thrown == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func completeAndStreamShareOneRetryBudgetOnTheSameScript() async throws {
    // given — a clean 5xx then success, on both entry points
    let completeHarness = ProviderHarness(
      steps: [
        .stream(head(500), Fixtures.errorBody("boom")),
        .stream(okHead, Fixtures.richSuccess()),
      ]
    )
    let streamHarness = ProviderHarness(
      steps: [
        .stream(head(500), Fixtures.errorBody("boom")),
        .stream(okHead, Fixtures.richSuccess()),
      ]
    )

    // when
    let completed = try await completeHarness.provider.complete(request: plainRequest)
    let drained = await drain(streamHarness.provider.stream(request: plainRequest))

    // then — the same two wire attempts and the same terminal reply
    #expect(await completeHarness.http.recorded.count == 2)
    #expect(await streamHarness.http.recorded.count == 2)
    guard case .completed(let streamed) = drained.terminal else {
      Issue.record("expected a completed stream, got \(drained.terminal)")
      return
    }
    #expect(completed == streamed)
  }

  // MARK: - Obligation 1: budget-exhausted clean failure carries notStarted

  @Test(.timeLimit(.minutes(1)))
  func aBudgetExhaustedCleanFailureCarriesNotStartedAccountingToTheCaller() async throws {
    // given — two clean 5xx heads at a budget of two, so the retry exhausts on a proven-clean attempt
    let harness = ProviderHarness(
      steps: [
        .stream(head(500), Fixtures.errorBody("boom")),
        .stream(head(500), Fixtures.errorBody("boom")),
      ],
      retryBudget: 2
    )

    // when
    let failure = await requireProviderFailure {
      try await harness.provider.complete(request: plainRequest)
    }

    // then — the whole ProviderFailure survived: a clean 5xx reports notStarted, so no debit follows
    #expect(failure.accounting == .notStarted)
    #expect(failure.cause == .retryable(status: 500, message: "boom"))
  }

  // MARK: - Obligation 2: route-incompatible fields never dispatch

  @Test(.timeLimit(.minutes(1)))
  func aNonNilStopStringRecordsNoHTTPCallOnEitherPath() async throws {
    // given
    let stopping = ChatRequest(
      model: "gpt-5",
      messages: [ChatMessage(role: .user, content: "hello")],
      maxOutputTokens: 256,
      stop: ["STOP"]
    )
    let completeHarness = ProviderHarness(steps: [.stream(okHead, Fixtures.basicSuccess())])
    let streamHarness = ProviderHarness(steps: [.stream(okHead, Fixtures.basicSuccess())])

    // when
    let failure = await requireProviderFailure {
      try await completeHarness.provider.complete(request: stopping)
    }
    let drained = await drain(streamHarness.provider.stream(request: stopping))

    // then — no dispatch on either path, and the refusal is notStarted
    #expect(await completeHarness.http.recorded.isEmpty)
    #expect(await streamHarness.http.recorded.isEmpty)
    #expect(failure.accounting == .notStarted)
    if case .failed(let streamFailure) = drained.terminal {
      #expect(streamFailure.accounting == .notStarted)
    } else {
      Issue.record("expected a failed stream, got \(drained.terminal)")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func structuredOutputRecordsNoHTTPCall() async throws {
    // given — structured output is not off on this route
    let structured = ChatRequest(
      model: "gpt-5",
      messages: [ChatMessage(role: .user, content: "hello")],
      maxOutputTokens: 256,
      responseFormat: .jsonObject
    )
    let harness = ProviderHarness(steps: [.stream(okHead, Fixtures.basicSuccess())])

    // when
    let failure = await requireProviderFailure {
      try await harness.provider.complete(request: structured)
    }

    // then
    #expect(await harness.http.recorded.isEmpty)
    #expect(failure.accounting == .notStarted)
  }

  @Test(.timeLimit(.minutes(1)))
  func aRouteCompatibleRequestDoesDispatch() async throws {
    // given — the paired positive: without stop or structured output, the request reaches the wire
    let harness = ProviderHarness(steps: [.stream(okHead, Fixtures.basicSuccess())])

    // when
    _ = try await harness.provider.complete(request: plainRequest)

    // then
    #expect(await harness.http.recorded.count == 1)
  }

  // MARK: - Obligation 3: a real drops reporter, metadata only

  @Test(.timeLimit(.minutes(1)))
  func aDroppedForeignStateEmitsAMetadataOnlyDiagnostic() async throws {
    // given — history carrying a state from another provider, and a captured reporter
    let recorder = DropsRecorder()
    let request = ChatRequest(
      model: "gpt-5",
      messages: [
        ChatMessage(role: .user, content: "hi"),
        ChatMessage(
          role: .assistant,
          content: "answer",
          providerState: ProviderExchangeState(
            issuer: "some-other-provider:deadbeef",
            payload: Data("{}".utf8)
          )
        ),
      ],
      maxOutputTokens: 256
    )
    let harness = ProviderHarness(
      steps: [.stream(okHead, Fixtures.basicSuccess())],
      replayDropsReporter: { drops in
        recorder.record(drops)
      }
    )

    // when
    _ = try await harness.provider.complete(request: request)

    // then — the foreign state was counted and reported; the type carries counts and nothing else
    let drops = try #require(recorder.value)
    #expect(drops.foreign == 1)
    #expect(drops.total == 1)
  }

  // MARK: - Obligation 4: chronological replay emission

  @Test(.timeLimit(.minutes(1)))
  func selectedReplayHistoryEmitsInOriginalChronologicalOrder() async throws {
    // given — two compatible replay states of the same epoch, in two separate assistant turns
    let identity = ChatGPTReplayIdentity(
      profileID: fixedProfileID,
      wireModel: "gpt-5",
      epoch: fixedEpoch
    )
    let codec = ChatGPTProviderStateCodec(newEpoch: { fixedEpoch })
    let stateA = try codec.encodeResponseState(
      items: ChatGPTReplayItems(
        reasoning: [ChatGPTReasoningItem(encryptedContent: "ENC-A")],
        assistantMessages: [ChatGPTAssistantMessageItem(outputText: ["first answer"])]
      ),
      identity: identity
    )
    let stateB = try codec.encodeResponseState(
      items: ChatGPTReplayItems(
        reasoning: [ChatGPTReasoningItem(encryptedContent: "ENC-B")],
        assistantMessages: [ChatGPTAssistantMessageItem(outputText: ["second answer"])]
      ),
      identity: identity
    )
    let request = ChatRequest(
      model: "gpt-5",
      messages: [
        ChatMessage(role: .user, content: "u1"),
        ChatMessage(role: .assistant, content: "first answer", providerState: stateA),
        ChatMessage(role: .user, content: "u2"),
        ChatMessage(role: .assistant, content: "second answer", providerState: stateB),
        ChatMessage(role: .user, content: "u3"),
      ],
      maxOutputTokens: 256
    )
    let harness = ProviderHarness(steps: [.stream(okHead, Fixtures.basicSuccess())])

    // when
    _ = try await harness.provider.complete(request: request)

    // then — the replayed reasoning and messages appear in the history's own order
    let recorded = try #require(await harness.http.recorded.first)
    let body = try decodeBody(recorded.body)
    let input = try #require(body["input"] as? [[String: Any]])
    let encrypted = input.compactMap { item in item["encrypted_content"] as? String }
    #expect(encrypted == ["ENC-A", "ENC-B"])
    let assistantTexts = assistantOutputTexts(input)
    #expect(assistantTexts == ["first answer", "second answer"])
  }

  // MARK: - Obligation 5: a delta after its done item is suppressed

  @Test(.timeLimit(.minutes(1)))
  func aVisibleDeltaAfterItsDoneItemIsNotPublished() async throws {
    // given — a stream that emits a late delta after the item has already been declared done
    let harness = ProviderHarness(steps: [.stream(okHead, Fixtures.deltaAfterDone())])

    // when
    let drained = await drain(harness.provider.stream(request: plainRequest))

    // then — only the pre-done delta is published, and the final content never grows past it
    let deltas = drained.events.compactMap { event -> String? in
      guard case .delta(let text) = event else { return nil }
      return text
    }
    #expect(deltas == ["Hello"])
    guard case .completed(let response) = drained.terminal else {
      Issue.record("expected a completed stream, got \(drained.terminal)")
      return
    }
    #expect(response.content == "Hello")
  }

  // MARK: - Logged-out provider

  @Test(.timeLimit(.minutes(1)))
  func aLoggedOutProviderFailsAuthenticationBeforeInference() async throws {
    // given — no profile ID and a credential source that cannot authorize
    let harness = ProviderHarness(
      steps: [.stream(okHead, Fixtures.basicSuccess())],
      credentials: ScriptedLLMCredentialSource(failure: CredentialUnavailable()),
      credentialProfileID: nil
    )

    // when
    let failure = await requireProviderFailure {
      try await harness.provider.complete(request: plainRequest)
    }

    // then — authentication fails and nothing reached the wire
    #expect(failure.cause == .authenticationRequired)
    #expect(failure.accounting == .notStarted)
    #expect(await harness.http.recorded.isEmpty)
  }
}

// MARK: - Harness

private struct ProviderHarness {
  let http: ScriptedHTTPExecutor
  let provider: ChatGPTResponsesProvider<ScriptedClock>

  init(
    steps: [ScriptedHTTPExecutor.Step],
    credentials: any LLMCredentialSource = ProviderHarness.defaultCredentials,
    credentialProfileID: UUID? = fixedProfileID,
    retryBudget: Int = 3,
    replayDropsReporter: (@Sendable (ChatGPTReplayDrops) -> Void)? = nil
  ) {
    let http = ScriptedHTTPExecutor(steps)
    self.http = http
    let sleeps = SleepRecorder()
    self.provider = ChatGPTResponsesProvider(
      http: http,
      credentials: credentials,
      credentialProfileID: credentialProfileID,
      buildVersion: "1.2.3-test",
      retryBudget: retryBudget,
      requestTimeoutSeconds: 30,
      clock: ScriptedClock { delay in
        await sleeps.record(delay / .seconds(1))
      },
      jitter: { duration in duration },
      epochID: { fixedEpoch },
      logger: Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() }),
      replayDropsReporter: replayDropsReporter
    )
  }

  static var defaultCredentials: ScriptedLLMCredentialSource {
    ScriptedLLMCredentialSource(
      headers: ["Authorization": "Bearer test-token"],
      redactionValues: ["test-token"]
    )
  }
}

// MARK: - Recorders

/// Captures the last replay-drops diagnostic the provider emitted, proving the codec's reporter is
/// wired rather than left as the default no-op.
private final class DropsRecorder: Sendable {
  private let box = Mutex<ChatGPTReplayDrops?>(nil)

  func record(_ drops: ChatGPTReplayDrops) {
    box.withLock { current in
      current = drops
    }
  }

  var value: ChatGPTReplayDrops? {
    box.withLock { current in
      current
    }
  }
}

// MARK: - Assertions

private func requireProviderFailure(
  _ body: () async throws -> some Any
) async -> ProviderFailure {
  do {
    _ = try await body()
    Issue.record("expected the call to throw a ProviderFailure")
    return ProviderFailure(
      cause: .terminal(status: nil, message: "unreached"),
      accounting: .notStarted
    )
  } catch let failure as ProviderFailure {
    return failure
  } catch {
    Issue.record("expected a ProviderFailure, got \(error)")
    return ProviderFailure(
      cause: .terminal(status: nil, message: "unreached"),
      accounting: .notStarted
    )
  }
}

private func assistantOutputTexts(_ input: [[String: Any]]) -> [String] {
  input.compactMap { item -> String? in
    guard
      item["type"] as? String == "message",
      item["role"] as? String == "assistant",
      let content = item["content"] as? [[String: Any]]
    else {
      return nil
    }
    return content.compactMap { part in part["text"] as? String }.joined()
  }
}

// MARK: - Fixtures

private func fixedUUID(_ value: String) -> UUID {
  guard let parsed = UUID(uuidString: value) else {
    preconditionFailure("invalid fixed UUID \(value)")
  }
  return parsed
}

private let fixedProfileID = fixedUUID("00000000-0000-0000-0000-0000000000AA")
private let fixedEpoch = fixedUUID("11111111-1111-1111-1111-111111111111")

private let okHead = HTTPStreamHead(statusCode: 200, headers: [:])

private func head(_ status: Int) -> HTTPStreamHead {
  HTTPStreamHead(statusCode: status, headers: [:])
}

private let plainRequest = ChatRequest(
  model: "gpt-5",
  messages: [ChatMessage(role: .user, content: "hello")],
  maxOutputTokens: 256
)

private let sessionedRequest = ChatRequest(
  model: "gpt-5",
  messages: [ChatMessage(role: .user, content: "hello")],
  maxOutputTokens: 256,
  sessionId: "sess-1"
)

private enum Fixtures {
  static func event(_ json: String) -> Data {
    Data("data: \(json)\n\n".utf8)
  }

  /// A minimal success: an announced message, one visible delta, its done item, and a completed
  /// terminal with usage.
  static func basicSuccess() -> [Data] {
    [
      event(
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
      ),
      event(#"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#),
      event(
        #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#
      ),
      completedTerminal(),
    ]
  }

  /// Visible text, reasoning replay material, and a tool call — everything a terminal reply carries,
  /// so parity is asserted across every field rather than just the visible content.
  static func richSuccess() -> [Data] {
    [
      event(
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
      ),
      event(#"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#),
      event(
        #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#
      ),
      event(
        #"{"type":"response.output_item.added","output_index":1,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"ENC"}}"#
      ),
      event(
        #"{"type":"response.output_item.done","output_index":1,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"ENC"}}"#
      ),
      event(
        #"{"type":"response.output_item.added","output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"clock"}}"#
      ),
      event(
        #"{"type":"response.output_item.done","output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"clock","arguments":"{}"}}"#
      ),
      completedTerminal(),
    ]
  }

  /// A late visible delta arriving after its item has already been declared done.
  static func deltaAfterDone() -> [Data] {
    [
      event(
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
      ),
      event(#"{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}"#),
      event(
        #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#
      ),
      event(#"{"type":"response.output_text.delta","output_index":0,"delta":"EXTRA"}"#),
      completedTerminal(),
    ]
  }

  static func errorBody(_ message: String) -> [Data] {
    [Data(#"{"error":{"message":"\#(message)"}}"#.utf8)]
  }

  static func completedTerminal() -> Data {
    event(
      #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}"#
    )
  }
}
