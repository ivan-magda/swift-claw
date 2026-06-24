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
      guard case ProviderError.terminal(let status, _) = error else { return false }
      return status == 400
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
      guard case ProviderError.retryable(let status, _) = error else { return false }
      return status == 500
    }
    let attempts = await exec.recorded.count
    #expect(attempts == 3)
  }

  @Test func transportErrorRedactsTheApiKey() async throws {
    // given — a transport error whose text embeds the key; retried then surfaced
    let apiKey = "sk-super-secret-123"
    let exec = ScriptedHTTPExecutor([
      .fail(TransportFailure(message: "connection reset with key \(apiKey)")),
      .fail(TransportFailure(message: "connection reset with key \(apiKey)")),
      .fail(TransportFailure(message: "connection reset with key \(apiKey)")),
    ])
    let provider = makeProvider(config: makeConfig(apiKey: apiKey, retryBudget: 3), http: exec)

    // when
    var thrownMessage: String?
    await #expect {
      _ = try await provider.complete(request: sampleRequest)
    } throws: { error in
      guard case ProviderError.retryable(_, let message) = error else { return false }
      thrownMessage = message
      return true
    }

    // then
    let message = try #require(thrownMessage)
    #expect(message.contains(apiKey) == false)
    #expect(message.contains("<redacted-key>"))
    let attempts = await exec.recorded.count
    #expect(attempts == 3)
  }

  @Test func isReasoningModelDetectsKnownPrefixes() {
    // then
    #expect(OpenAICompatibleProvider.isReasoningModel("o3-mini"))
    #expect(OpenAICompatibleProvider.isReasoningModel("gpt-5-reasoning"))
    #expect(OpenAICompatibleProvider.isReasoningModel("gpt-4o") == false)
  }
}
