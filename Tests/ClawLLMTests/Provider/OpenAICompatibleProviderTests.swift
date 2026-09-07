import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore
@testable import ClawLLM

@Suite struct OpenAICompatibleProviderTests {
  @Test func sendsModelMessagesAndDefaultMaxCompletionTokens() async throws {
    // given
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    _ = try await provider.complete(request: sampleRequest)

    // then
    let recorded = try #require(await exec.recorded.first)
    let body = try decodeBody(recorded.body)
    #expect(body["max_completion_tokens"] as? Int == 256)
    #expect(body["stream"] as? Bool == false)
    #expect(body["model"] as? String == "gpt-4o")
    #expect(body["messages"] is [Any])
    #expect(recorded.headers["Authorization"] == "Bearer sk-test")
    #expect(recorded.headers["Content-Type"] == "application/json")
    // The wire attempt carried its linearization handoff, run before the request was recorded.
    #expect(recorded.carriedHandoff)
    #expect(recorded.url == "https://api.test/v1/chat/completions")
  }

  @Test func switchesToMaxTokensFieldAndOmitsAuthWhenKeyEmpty() async throws {
    // given
    let config = makeConfig(maxTokensField: .maxTokens, apiKey: "")
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(config: config, http: exec)

    // when
    _ = try await provider.complete(request: sampleRequest)

    // then
    let recorded = try #require(await exec.recorded.first)
    let body = try decodeBody(recorded.body)
    #expect(body["max_tokens"] as? Int == 256)
    #expect(body["max_completion_tokens"] == nil)
    #expect(recorded.headers["Authorization"] == nil)
  }

  @Test func omitsResponseFormatWhenUnset() async throws {
    // given — a plain turn request carries no structured-output directive
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    _ = try await provider.complete(request: sampleRequest)

    // then
    let recorded = try #require(await exec.recorded.first)
    let body = try decodeBody(recorded.body)
    #expect(body["response_format"] == nil)
  }

  @Test func encodesJSONObjectResponseFormat() async throws {
    // given
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(config: makeConfig(), http: exec)
    let request = ChatRequest(
      model: "gpt-4o",
      messages: [ChatMessage(role: .user, content: "hi")],
      maxOutputTokens: 256,
      responseFormat: .jsonObject
    )

    // when
    _ = try await provider.complete(request: request)

    // then
    let recorded = try #require(await exec.recorded.first)
    let body = try decodeBody(recorded.body)
    let responseFormat = try #require(body["response_format"] as? [String: Any])
    #expect(responseFormat["type"] as? String == "json_object")
  }

  @Test func encodesJSONSchemaResponseFormatAsStrict() async throws {
    // given
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(config: makeConfig(), http: exec)
    let request = ChatRequest(
      model: "gpt-4o",
      messages: [ChatMessage(role: .user, content: "hi")],
      maxOutputTokens: 256,
      responseFormat: .jsonSchema(name: "draft", schema: .object(["type": .string("object")]))
    )

    // when
    _ = try await provider.complete(request: request)

    // then — the OpenAI structured-outputs envelope: name + strict + the schema object
    let recorded = try #require(await exec.recorded.first)
    let body = try decodeBody(recorded.body)
    let responseFormat = try #require(body["response_format"] as? [String: Any])
    #expect(responseFormat["type"] as? String == "json_schema")
    let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
    #expect(jsonSchema["name"] as? String == "draft")
    #expect(jsonSchema["strict"] as? Bool == true)
    #expect(jsonSchema["schema"] is [String: Any])
  }

  @Test func emitsSessionIdWhenProviderIsOpenRouter() async throws {
    // given — an OpenRouter base URL and a request carrying a session trace id
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(
      config: makeConfig(baseURL: "https://openrouter.ai/api/v1"),
      http: exec
    )
    let request = ChatRequest(
      model: "gpt-4o",
      messages: [ChatMessage(role: .user, content: "hi")],
      maxOutputTokens: 256,
      sessionId: "clawd-session-7"
    )

    // when
    _ = try await provider.complete(request: request)

    // then — the proprietary OpenRouter grouping field rides the body
    let recorded = try #require(await exec.recorded.first)
    let body = try decodeBody(recorded.body)
    #expect(body["session_id"] as? String == "clawd-session-7")
  }

  @Test func omitsSessionIdWhenProviderIsNotOpenRouter() async throws {
    // given — the same session-carrying request but a non-OpenRouter host
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(
      config: makeConfig(baseURL: "https://api.openai.com/v1"),
      http: exec
    )
    let request = ChatRequest(
      model: "gpt-4o",
      messages: [ChatMessage(role: .user, content: "hi")],
      maxOutputTokens: 256,
      sessionId: "clawd-session-7"
    )

    // when
    _ = try await provider.complete(request: request)

    // then — the key is absent so the body stays a plain OpenAI-compatible request
    let recorded = try #require(await exec.recorded.first)
    let body = try decodeBody(recorded.body)
    #expect(body["session_id"] == nil)
  }

  @Test func omitsSessionIdWhenRequestHasNone() async throws {
    // given — OpenRouter host but the request carries no session id
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(
      config: makeConfig(baseURL: "https://openrouter.ai/api/v1"),
      http: exec
    )
    let request = ChatRequest(
      model: "gpt-4o",
      messages: [ChatMessage(role: .user, content: "hi")],
      maxOutputTokens: 256
    )

    // when
    _ = try await provider.complete(request: request)

    // then — nil session id encodes no key (not a null)
    let recorded = try #require(await exec.recorded.first)
    let body = try decodeBody(recorded.body)
    #expect(body["session_id"] == nil)
  }

  @Test(
    arguments: [
      ("https://openrouter.ai/api/v1", true),
      ("https://OpenRouter.ai/api/v1", true),
      ("https://api.openai.com/v1", false),
      ("http://localhost:11434/v1", false),
      ("", false),
      ("not a url", false),
    ]
  )
  func baseURLIsOpenRouterDetectsHost(baseURL: String, expected: Bool) {
    // given / when / then — detection is an exact, case-insensitive host match
    #expect(OpenAICompatibleProvider.baseURLIsOpenRouter(baseURL) == expected)
  }

  @Test func nullContentBecomesEmptyAndAbsentUsageBecomesNil() async throws {
    // given — Ollama-style: null content and no usage object
    let json = #"{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":null}}]}"#
    let exec = ScriptedHTTPExecutor([
      .ok(HTTPResult(statusCode: 200, headers: [:], body: Data(json.utf8)))
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    let response = try await provider.complete(request: sampleRequest)

    // then — absent usage is nil (not a zero row), so the agent estimates it rather than
    // recording zero tokens.
    #expect(response.content.isEmpty)
    #expect(response.usage == nil)
  }

  @Test func parsesProviderCostFromUsageField() async throws {
    // given — OpenRouter carries cost in usage.cost
    let json = """
      {"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"hi"},
      "finish_reason":"stop"}],
      "usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"cost":0.0012}}
      """
    let exec = ScriptedHTTPExecutor([
      .ok(HTTPResult(statusCode: 200, headers: [:], body: Data(json.utf8)))
    ])

    // when
    let response = try await makeProvider(config: makeConfig(), http: exec)
      .complete(request: sampleRequest)

    // then
    #expect(response.costFromProvider == 0.0012)
  }

  @Test func parsesProviderCostFromLiteLLMHeader() async throws {
    // given — LiteLLM carries cost in a response header
    let exec = ScriptedHTTPExecutor([
      okStep(headers: ["x-litellm-response-cost": "0.0034"])
    ])

    // when
    let response = try await makeProvider(config: makeConfig(), http: exec)
      .complete(request: sampleRequest)

    // then
    #expect(response.costFromProvider == 0.0034)
  }

  @Test func maps400ToTerminalWithoutRetry() async throws {
    // given
    let exec = ScriptedHTTPExecutor([errorStep(400)])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    await #expect {
      _ = try await provider.complete(request: sampleRequest)
    } throws: { error in
      // The buffered path wraps its cause in a ProviderFailure that carries the accounting: a clean
      // 4xx head generated nothing, so the failure is notStarted.
      guard case .terminal(let status, _)? = ProviderError.cause(of: error) else {
        return false
      }
      return status == 400 && ProviderFailureAccounting.classify(error) == .notStarted
    }
    let attempts = await exec.recorded.count
    #expect(attempts == 1)
  }

  @Test func retriesRetryableUntilSuccessHonoringRetryAfter() async throws {
    // given — two 503s (first carries Retry-After: 2), then a 200
    let exec = ScriptedHTTPExecutor([
      errorStep(503, headers: ["Retry-After": "2"]),
      errorStep(503),
      okStep(),
    ])
    let recorder = SleepRecorder()
    let provider = makeProvider(config: makeConfig(), http: exec, recorder: recorder)

    // when
    _ = try await provider.complete(request: sampleRequest)

    // then
    let attempts = await exec.recorded.count
    let delays = await recorder.delays
    #expect(attempts == 3)
    #expect(delays.count == 2)
    #expect(delays.first == 2.0)
    // second 503 has no Retry-After; exponential = 0.5 * 2^(2-1) = 1.0, jitter returns 0
    #expect(delays[1] == 0.0)
  }

  @Test func exhaustedRetriesThrowRetryable() async throws {
    // given — every attempt is a 500; the retry budget is 3
    let exec = ScriptedHTTPExecutor([errorStep(500), errorStep(500), errorStep(500)])
    let provider = makeProvider(config: makeConfig(retryBudget: 3), http: exec)

    // when
    await #expect {
      _ = try await provider.complete(request: sampleRequest)
    } throws: { error in
      // Each 500 was proven clean before the exhausting throw, so the wrapped failure charges no
      // phantom usage — it is notStarted, not the case-guessed mayHaveStarted.
      guard case .retryable(let status, _)? = ProviderError.cause(of: error) else {
        return false
      }
      return status == 500 && ProviderFailureAccounting.classify(error) == .notStarted
    }
    let attempts = await exec.recorded.count
    #expect(attempts == 3)
  }

  @Test func backoffGrowsExponentiallyAndClampsAtTheMaxCap() async throws {
    // given — every attempt is a retryable 500 with no Retry-After, so each retry uses the
    // exponential schedule; an identity jitter exposes the raw computed delay and the recorder
    // captures every sleep the provider requests
    let exec = ScriptedHTTPExecutor(Array(repeating: errorStep(500), count: 9))
    let recorder = SleepRecorder()
    let provider = makeProvider(
      config: makeConfig(retryBudget: 9),
      http: exec,
      recorder: recorder,
      jitter: { $0 }
    )

    // when — the budget is exhausted after 9 attempts (8 backoffs between them)
    await #expect {
      _ = try await provider.complete(request: sampleRequest)
    } throws: { error in
      guard case .retryable(let status, _)? = ProviderError.cause(of: error) else {
        return false
      }
      return status == 500
    }

    // then — 0.5·2^(attempt-1) doubling, clamped at the 30 s cap for attempts 7 and 8
    let delays = await recorder.delays
    #expect(delays == [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0])
    #expect(await exec.recorded.count == 9)
  }

  @Test func transportErrorRedactsTheApiKey() async throws {
    // given — a proven-clean transport error whose text embeds the key; retried then surfaced. The
    // disposition is definitely-not-sent so the retry-through-to-exhaustion path this test covers is
    // the one the new rule still permits.
    let apiKey = "sk-super-secret-123"
    let failure = HTTPTransportFailure(
      disposition: .definitelyNotSent,
      safeMessage: "connection reset with key \(apiKey)"
    )
    let exec = ScriptedHTTPExecutor([
      .transportFailure(failure),
      .transportFailure(failure),
      .transportFailure(failure),
    ])
    let provider = makeProvider(config: makeConfig(apiKey: apiKey, retryBudget: 3), http: exec)

    // when
    var thrownMessage: String?
    await #expect {
      _ = try await provider.complete(request: sampleRequest)
    } throws: { error in
      guard case .retryable(_, let message)? = ProviderError.cause(of: error) else {
        return false
      }
      thrownMessage = message
      return true
    }

    // then
    let message = try #require(thrownMessage)
    #expect(message.contains(apiKey) == false)
    #expect(message.contains(SecretRedactor.replacement))
    let attempts = await exec.recorded.count
    #expect(attempts == 3)
  }

  @Test func definitelyNotSentTransportFailureRetriesUpToBudget() async throws {
    // given — two proven-clean transport failures then a success; nothing could have reached the
    // model, so the attempt is safe to replay up to the budget
    let exec = ScriptedHTTPExecutor([
      .transportFailure(
        HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: "refused")
      ),
      .transportFailure(
        HTTPTransportFailure(disposition: .definitelyNotSent, safeMessage: "refused")
      ),
      okStep(content: "recovered"),
    ])
    let provider = makeProvider(config: makeConfig(retryBudget: 3), http: exec)

    // when
    let response = try await provider.complete(request: sampleRequest)

    // then — the success is returned only after both clean failures were replayed
    #expect(response.content == "recovered")
    #expect(await exec.recorded.count == 3)
  }

  @Test func mayHaveBeenSentTransportFailureIsNotRetried() async throws {
    // given — an ambiguous send a retry could double-charge; a success step waits behind it that the
    // provider must never reach
    let exec = ScriptedHTTPExecutor([
      .transportFailure(
        HTTPTransportFailure(disposition: .mayHaveBeenSent, safeMessage: "dropped")
      ),
      okStep(content: "must-not-be-reached"),
    ])
    let provider = makeProvider(config: makeConfig(retryBudget: 3), http: exec)

    // when
    await #expect {
      _ = try await provider.complete(request: sampleRequest)
    } throws: { error in
      // The attempt reached the transport and cannot be proven clean, so the failure carries
      // conservative accounting rather than being replayed.
      guard case .retryable(let status, _)? = ProviderError.cause(of: error) else {
        return false
      }
      return status == nil
        && ProviderFailureAccounting.classify(error) == .mayHaveStarted(observing: 0)
    }

    // then — exactly one dispatch; the queued success was never asked for
    #expect(await exec.recorded.count == 1)
  }

  @Test func streamRequestEnablesStreamOptionsAndYieldsEvents() async throws {
    // given
    let chunks = [
      Data(#"data: {"choices":[{"delta":{"content":"he"}}]}"#.utf8),
      Data("\n\n".utf8),
      Data(
        #"data: {"choices":[{"delta":{"content":"llo"},"finish_reason":"stop"}]}"#.utf8
      ),
      Data("\n\n".utf8),
      Data(
        #"data: {"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}"#
          .utf8
      ),
      Data("\n\n".utf8),
      Data("data: [DONE]\n\n".utf8),
    ]
    let exec = ScriptedHTTPExecutor([
      .stream(HTTPStreamHead(statusCode: 200, headers: [:]), chunks)
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    let (events, thrown, terminal) = await drain(provider.stream(request: sampleRequest))

    // then
    let recorded = try #require(await exec.recorded.first)
    let body = try decodeBody(recorded.body)
    let streamOptions = try #require(body["stream_options"] as? [String: Any])
    #expect(body["stream"] as? Bool == true)
    #expect(streamOptions["include_usage"] as? Bool == true)
    // The 4 MiB unread allowance is a plan-wide bound, so pin the value the provider actually
    // plumbs: the exchange tests prove the mechanism, only this proves the number reaches it.
    #expect(
      recorded.responseBodyPolicy
        == .streaming(maximumUnreadBytes: 4 * 1024 * 1024, errorBytes: 64 * 1024)
    )
    // The attempt carried its linearization handoff, run before the request reached the transport.
    #expect(recorded.carriedHandoff)
    #expect(thrown == nil)

    let reply = ChatResponse(
      content: "hello",
      finishReason: "stop",
      usage: ChatUsage(promptTokens: 4, completionTokens: 2, totalTokens: 6),
      costFromProvider: nil
    )
    #expect(events == [.delta("he"), .delta("llo"), .finished(reply)])
    // Joining the session reports the same reply the terminal event carried.
    #expect(terminal == .completed(reply))
  }

  @Test func streamUsesLiteLLMCostHeaderWhenUsageCostIsAbsent() async throws {
    // given
    let chunks = [
      Data(#"data: {"choices":[{"delta":{"content":"hello"},"finish_reason":"stop"}]}"#.utf8),
      Data("\n\n".utf8),
      Data(
        #"data: {"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}"#
          .utf8
      ),
      Data("\n\n".utf8),
      Data("data: [DONE]\n\n".utf8),
    ]
    let exec = ScriptedHTTPExecutor([
      .stream(
        HTTPStreamHead(statusCode: 200, headers: ["x-litellm-response-cost": "0.0034"]),
        chunks
      )
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    let (events, _, _) = await drain(provider.stream(request: sampleRequest))

    // then
    #expect(
      events.last
        == .finished(
          ChatResponse(
            content: "hello",
            finishReason: "stop",
            usage: ChatUsage(promptTokens: 4, completionTokens: 2, totalTokens: 6),
            costFromProvider: 0.0034
          )
        )
    )
  }

  @Test func streamNon2xxMapsWithoutRetrying() async throws {
    // given
    let errorBody = Data(#"{"error":{"message":"bad auth"}}"#.utf8)
    let exec = ScriptedHTTPExecutor([
      .stream(HTTPStreamHead(statusCode: 401, headers: [:]), [errorBody])
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    let (_, thrown, terminal) = await drain(provider.stream(request: sampleRequest))

    // then — a recognized error head proves the server answered instead of inferring, so the
    // attempt is accounted as never having started
    #expect(
      terminal
        == .failed(
          ProviderFailure(
            cause: .terminal(status: 401, message: "bad auth"),
            accounting: .notStarted
          )
        )
    )
    #expect((thrown as? ProviderFailure)?.cause == .terminal(status: 401, message: "bad auth"))
    #expect(await exec.recorded.count == 1)
  }

  @Test func streamRetryableClassNon2xxMapsToRejectedWithoutRetrying() async throws {
    // given
    let errorBody = Data(#"{"error":{"message":"rate limited"}}"#.utf8)
    let exec = ScriptedHTTPExecutor([
      .stream(HTTPStreamHead(statusCode: 429, headers: ["Retry-After": "2"]), [errorBody])
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    let (_, thrown, terminal) = await drain(provider.stream(request: sampleRequest))

    // then — classified once as a clean pre-stream rejection; the stream itself never retries.
    // `.rejected` is what the turn's one-time buffered fallback keys on, so the case is load-bearing
    // and not an implementation detail.
    #expect(
      terminal
        == .failed(
          ProviderFailure(
            cause: .rejected(status: 429, message: "rate limited"),
            accounting: .notStarted
          )
        )
    )
    #expect((thrown as? ProviderFailure)?.cause == .rejected(status: 429, message: "rate limited"))
    #expect(await exec.recorded.count == 1)
  }

  @Test func streamPostSendFailureDoesNotRetryOrFallbackInsideProvider() async throws {
    // given
    let exec = ScriptedHTTPExecutor([
      .streamFailure(
        HTTPStreamHead(statusCode: 200, headers: [:]),
        [],
        ScriptedTransportFailure(message: "dropped after request")
      )
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    let (_, thrown, terminal) = await drain(provider.stream(request: sampleRequest))

    // then — the head was fine, so the failure came after the request was written: retryable, and
    // conservatively accounted since the model may already have generated
    let failure = try #require(thrown as? ProviderFailure)
    guard case .retryable(let status, let message) = failure.cause else {
      Issue.record("expected a retryable cause, got \(failure.cause)")
      return
    }
    #expect(status == nil)
    #expect(message.contains("dropped after request"))
    #expect(failure.accounting == .mayHaveStarted(observing: 0))
    #expect(terminal == .failed(failure))
    #expect(await exec.recorded.count == 1)
  }

  @Test func cancellingTheStreamJoinsItsHTTPExchange() async throws {
    // given — a transfer whose producer acknowledges nothing until its gate opens, so the join
    // cannot resolve early by luck
    let gate = AsyncGate()
    defer { gate.open() }
    let exec = ScriptedHTTPExecutor([
      .blockedStream(
        HTTPStreamHead(statusCode: 200, headers: [:]),
        [Data("data: [DONE]\n\n".utf8)],
        ScriptedStreamHold(release: gate)
      )
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)
    let stream = provider.stream(request: sampleRequest)

    // Let the producer get inside its exchange; cancelling before the request is dispatched would
    // test the authorization path instead of the join.
    while await exec.recorded.isEmpty {
      await Task.yield()
    }

    // when
    let joined = CompletionFlag()
    let joinTask = Task { () -> LLMStreamTermination in
      let terminal = await stream.cancelAndAwait()
      await joined.markDone()
      return terminal
    }
    // A yield lets an (incorrect) join that abandoned its exchange surface, without a wall-clock
    // window.
    await Task.yield()
    let joinedWhileTransferParked = await joined.done
    gate.open()
    let terminal = await joinTask.value

    // then — joining the session waits out the transfer nested inside it
    #expect(joinedWhileTransferParked == false)
    // The request reached the transport, so cancellation is conservative.
    #expect(terminal == .cancelled(.mayHaveStarted(observing: 0)))
  }

  @Test func streamConnectFailureIsTypedForRuntimeFallback() async throws {
    // given — a transport failure that proves nothing was sent; the runtime's stream-to-buffered
    // fallback turns on that fact and nothing else
    let exec = ScriptedHTTPExecutor([
      .transportFailure(
        HTTPTransportFailure(
          disposition: .definitelyNotSent,
          safeMessage: "connection refused sk-test"
        )
      )
    ])
    let provider = makeProvider(config: makeConfig(), http: exec)

    // when
    let (_, thrown, terminal) = await drain(provider.stream(request: sampleRequest))

    // then
    let failure = try #require(thrown as? ProviderFailure)
    guard case .connectFailed(let message) = failure.cause else {
      Issue.record("expected a connectFailed cause, got \(failure.cause)")
      return
    }
    #expect(message.contains("sk-test") == false)
    #expect(message.contains(SecretRedactor.replacement))
    // A definitely-not-sent failure proves the attempt generated nothing.
    #expect(failure.accounting == .notStarted)
    #expect(terminal == .failed(failure))
  }

  @Test func staticSourceSuppliesTheBearerAndItsRedaction() async throws {
    // given — the composition-root pairing: a configured key reaches the wire through the static
    // source, and the same value is what a diagnostic gets scrubbed of
    let apiKey = "sk-static-999"
    let exec = ScriptedHTTPExecutor([
      .fail(ScriptedTransportFailure(message: "reset with key \(apiKey)"))
    ])
    let provider = makeProvider(
      config: makeConfig(apiKey: "ignored-by-the-source", retryBudget: 1),
      http: exec,
      credentials: StaticLLMCredentialSource(bearer: apiKey)
    )

    // when
    var thrownMessage: String?
    await #expect {
      _ = try await provider.complete(request: sampleRequest)
    } throws: { error in
      guard case .retryable(_, let message)? = ProviderError.cause(of: error) else {
        return false
      }
      thrownMessage = message
      return true
    }

    // then — the source's bearer, not the config's, is on the wire and is what gets redacted
    let recorded = try #require(await exec.recorded.first)
    #expect(recorded.headers["Authorization"] == "Bearer \(apiKey)")
    let message = try #require(thrownMessage)
    #expect(message.contains(apiKey) == false)
    #expect(message.contains(SecretRedactor.replacement))
  }

  @Test func credentialHeadersOutsideTheAllowlistAreRefusedBeforeAnyRequest() async throws {
    // given — a source that tries to redirect the exchange through the header seam
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(
      config: makeConfig(),
      http: exec,
      credentials: ScriptedLLMCredentialSource(
        headers: ["Authorization": "Bearer ok", "Host": "evil.test", "X-Route": "elsewhere"]
      )
    )

    // when
    await #expect {
      _ = try await provider.complete(request: sampleRequest)
    } throws: { error in
      guard case ProviderError.terminal(let status, let message) = error else {
        return false
      }
      return status == nil && message.contains("Host")
    }

    // then — refused before dispatch, so nothing reached the transport at all
    #expect(await exec.recorded.isEmpty)
  }

  @Test func credentialSourceCannotReplaceAnAdapterOwnedHeader() async throws {
    // given — a source offering the one header the adapter owns
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(
      config: makeConfig(),
      http: exec,
      credentials: ScriptedLLMCredentialSource(headers: ["content-type": "text/plain"])
    )

    // when / then — content negotiation is the adapter's, whatever casing the source spells it in
    await #expect {
      _ = try await provider.complete(request: sampleRequest)
    } throws: { error in
      guard case ProviderError.terminal(_, let message) = error else {
        return false
      }
      return message.contains("content-type")
    }
    #expect(await exec.recorded.isEmpty)
  }

  @Test func authorizationFailureRequestsLoginWithoutSendingAnything() async throws {
    // given
    let exec = ScriptedHTTPExecutor([.stream(HTTPStreamHead(statusCode: 200, headers: [:]), [])])
    let provider = makeProvider(
      config: makeConfig(),
      http: exec,
      credentials: ScriptedLLMCredentialSource(failure: CredentialUnavailable())
    )

    // when
    let (_, _, terminal) = await drain(provider.stream(request: sampleRequest))

    // then — a redaction-safe cause that names the state rather than the source's own error
    #expect(
      terminal
        == .failed(ProviderFailure(cause: .authenticationRequired, accounting: .notStarted))
    )
    #expect(await exec.recorded.isEmpty)
  }

  @Test func bufferedAuthorizationFailureRequestsLoginWithoutSendingAnything() async throws {
    // given — the throwing source the streamed path is already proved against
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(
      config: makeConfig(),
      http: exec,
      credentials: ScriptedLLMCredentialSource(failure: CredentialUnavailable())
    )

    // when
    let thrown = await #expect(throws: ProviderError.self) {
      _ = try await provider.complete(request: sampleRequest)
    }

    // then — both entry points owe the same typed cause, and neither reaches the transport to get it
    #expect(thrown == .authenticationRequired)
    #expect(await exec.recorded.isEmpty)
  }

  @Test func providerStateIsNotEncodedByChatCompletions() async throws {
    // given — replay state on the outbound history; this route mints and understands none
    let exec = ScriptedHTTPExecutor([okStep()])
    let provider = makeProvider(config: makeConfig(), http: exec)
    let request = ChatRequest(
      model: "gpt-4o",
      messages: [
        ChatMessage(
          role: .assistant,
          content: "earlier",
          providerState: ProviderExchangeState(issuer: "other-route", payload: Data("op".utf8))
        ),
        ChatMessage(role: .user, content: "hello"),
      ],
      maxOutputTokens: 256
    )

    // when
    let response = try await provider.complete(request: request)

    // then — nothing of it rides the wire, and none comes back
    let recorded = try #require(await exec.recorded.first)
    let raw = try #require(String(data: recorded.body, encoding: .utf8))
    #expect(raw.contains("providerState") == false)
    #expect(raw.contains("provider_state") == false)
    #expect(raw.contains("other-route") == false)
    let messages = try #require(try decodeBody(recorded.body)["messages"] as? [[String: Any]])
    #expect(messages.count == 2)
    #expect(messages[0].keys.sorted() == ["content", "role"])
    #expect(response.providerState == nil)
  }
}
