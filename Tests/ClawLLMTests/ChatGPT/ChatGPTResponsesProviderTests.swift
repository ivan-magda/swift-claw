import ClawAuth
import ClawCore
import ClawTestSupport
import Foundation
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

  @Test(.timeLimit(.minutes(1)))
  func twoCasingsOfAuthorizationAreRejectedBeforeHTTPRatherThanSilentlyMerged() async throws {
    // given — a source handing back both spellings of Authorization carrying different bearers, which
    // the allowlist maps to one canonical key
    let credentials = ScriptedLLMCredentialSource(
      headers: ["Authorization": "Bearer canonical", "authorization": "Bearer shadow"],
      redactionValues: ["canonical", "shadow"]
    )
    let harness = ProviderHarness(
      steps: [.stream(okHead, Fixtures.basicSuccess())],
      credentials: credentials
    )

    // when
    let failure = await requireProviderFailure {
      try await harness.provider.complete(request: plainRequest)
    }

    // then — the collision is refused before any dispatch, so sort order never gets to pick the bearer
    #expect(await harness.http.recorded.isEmpty)
    #expect(failure.accounting == .notStarted)
    guard case .terminal(_, let message) = failure.cause else {
      Issue.record("expected a terminal refusal, got \(failure.cause)")
      return
    }
    #expect(message.contains("more than once"))
  }

  @Test(.timeLimit(.minutes(1)))
  func thePublicInitRunsTheDropPathAndStillDispatches() async throws {
    // given — the pinned public init (no injected logger or reporter) and a history carrying a foreign
    // state, so the production drop path runs end to end
    let http = ScriptedHTTPExecutor([.stream(okHead, Fixtures.basicSuccess())])
    let sleeps = SleepRecorder()
    let provider = ChatGPTResponsesProvider(
      http: http,
      credentials: Support.defaultCredentials,
      credentialProfileID: fixedProfileID,
      buildVersion: "1.2.3-test",
      retryBudget: 3,
      requestTimeoutSeconds: 30,
      clock: ScriptedClock { delay in
        await sleeps.record(delay / .seconds(1))
      },
      jitter: { duration in duration },
      epochID: { fixedEpoch }
    )
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

    // when — the public path drops the foreign state and still dispatches
    let response = try await provider.complete(request: request)

    // then — the public constructor wired a live codec and engine rather than throwing the drop away.
    // The bootstrapped logger's non-silence cannot be asserted here: the public init exposes no logger
    // or reporter seam, and observing it would need a process-global `LoggingSystem.bootstrap` that
    // breaks test isolation. Obligation 3's falsifiable coverage stays at the internal-seam test below.
    #expect(response.content == "Hello")
    #expect(await http.recorded.count == 1)
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

  // MARK: - Obligation 3: a real drops reporter, metadata only

  @Test(.timeLimit(.minutes(1)))
  func aDroppedForeignStateEmitsAMetadataOnlyDiagnostic() async throws {
    // given — history carrying a state from another provider, and a captured developer log
    let capture = RecordingLogCapture()
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
      logger: capture.logger()
    )

    // when
    _ = try await harness.provider.complete(request: request)

    // then — the foreign state was counted and reported as counts, carrying no payload or issuer
    let line = try #require(capture.entries.first { $0.message.contains("replay state dropped") })
    #expect(line.message.contains("foreign=1"))
    #expect(line.message.contains("staleEpoch=0"))
    #expect(line.message.contains("deadbeef") == false)
    #expect(line.message.contains("some-other-provider") == false)
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

// MARK: - Shared support

private typealias Support = ChatGPTProviderTestSupport
private typealias ProviderHarness = Support.Harness
private typealias Fixtures = Support.Fixtures

private let fixedProfileID = Support.fixedProfileID
private let fixedEpoch = Support.fixedEpoch
private let okHead = Support.okHead
private let plainRequest = Support.plainRequest
private let sessionedRequest = Support.sessionedRequest

private func head(_ status: Int) -> HTTPStreamHead {
  Support.head(status)
}

// MARK: - Recorders

/// Captures the last replay-drops diagnostic the provider emitted, proving the codec's reporter is
/// wired rather than left as the default no-op.
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
