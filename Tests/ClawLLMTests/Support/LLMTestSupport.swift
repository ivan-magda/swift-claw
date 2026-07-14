import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore
@testable import ClawLLM

// MARK: - Test doubles

/// A transport failure whose description can embed a secret, to test redaction.
struct TransportFailure: Error, CustomStringConvertible, Sendable {
  let message: String
  var description: String { message }
}

/// Plays back a scripted queue of HTTP outcomes and records every request it received,
/// so retry counts, request shaping, and header handling can be asserted.
actor ScriptedHTTPExecutor: HTTPExecuting, HTTPStreaming {
  enum Step: Sendable {
    case ok(HTTPResult)
    case fail(TransportFailure)
    case stream(HTTPStreamHead, [Data])
    case streamFailure(HTTPStreamHead, [Data], TransportFailure)
    case connectFailure(TransportFailure)
  }

  struct Recorded: Sendable {
    let url: String
    let headers: [String: String]
    let body: Data
    let timeoutSeconds: Int
  }

  private var steps: [Step]
  private(set) var recorded: [Recorded] = []

  init(_ steps: [Step]) {
    self.steps = steps
  }

  func post(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> HTTPResult {
    recorded.append(
      Recorded(url: url, headers: headers, body: jsonBody, timeoutSeconds: timeoutSeconds)
    )

    guard !steps.isEmpty else {
      throw TransportFailure(message: "scripted executor exhausted")
    }

    switch steps.removeFirst() {
    case .ok(let result): return result
    case .fail(let error): throw error
    case .connectFailure(let error): throw error
    case .stream, .streamFailure:
      throw TransportFailure(message: "expected buffered step, got streaming step")
    }
  }

  func get(
    url: String,
    headers: [String: String],
    timeoutSeconds: Int,
    maxBodyBytes: Int
  ) async throws -> HTTPResult {
    struct GetUnsupported: Error {}
    throw GetUnsupported()
  }

  func postStream(
    url: String,
    headers: [String: String],
    jsonBody: Data,
    timeoutSeconds: Int
  ) async throws -> (head: HTTPStreamHead, body: AsyncThrowingStream<Data, Error>) {
    recorded.append(
      Recorded(url: url, headers: headers, body: jsonBody, timeoutSeconds: timeoutSeconds)
    )

    guard !steps.isEmpty else {
      throw ProviderError.connectFailed(message: "scripted executor exhausted")
    }

    switch steps.removeFirst() {
    case .connectFailure(let error):
      throw ProviderError.connectFailed(message: error.message)
    case .stream(let head, let chunks):
      return (head, stream(chunks: chunks, failure: nil))
    case .streamFailure(let head, let chunks, let failure):
      return (head, stream(chunks: chunks, failure: failure))
    case .ok, .fail:
      throw ProviderError.connectFailed(message: "expected streaming step, got buffered step")
    }
  }

  private func stream(
    chunks: [Data],
    failure: TransportFailure?
  ) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      for chunk in chunks {
        continuation.yield(chunk)
      }
      if let failure {
        continuation.finish(throwing: failure)
      } else {
        continuation.finish()
      }
    }
  }
}

/// Records the delays the provider asks to sleep for, so `Retry-After` honoring is observable.
actor SleepRecorder {
  private(set) var delays: [Double] = []

  func record(_ seconds: Double) {
    delays.append(seconds)
  }
}

// MARK: - Builders

func makeConfig(
  baseURL: String = "https://api.test/v1",
  maxTokensField: MaxTokensField = .maxCompletionTokens,
  apiKey: String = "sk-test",
  model: String = "gpt-4o",
  maxOutputTokens: Int = 256,
  retryBudget: Int = 3
) -> LLMConfig {
  LLMConfig(
    baseURL: baseURL,
    model: model,
    apiKey: apiKey,
    maxTokensField: maxTokensField,
    maxOutputTokens: maxOutputTokens,
    retryBudget: retryBudget,
    requestTimeoutSeconds: 30
  )
}

func makeProvider(
  config: LLMConfig,
  http: any HTTPExecuting & HTTPStreaming,
  recorder: SleepRecorder = SleepRecorder(),
  jitter: @escaping @Sendable (Duration) -> Duration = { _ in .zero }
) -> OpenAICompatibleProvider {
  OpenAICompatibleProvider(
    config: config,
    http: http,
    clock: ScriptedClock { delay in
      await recorder.record(delay / .seconds(1))
    },
    jitter: jitter
  )
}

func okStep(
  content: String = "hi",
  finishReason: String = "stop",
  headers: [String: String] = [:]
) -> ScriptedHTTPExecutor.Step {
  let json = """
    {"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"\(content)"},
    "finish_reason":"\(finishReason)"}],
    "usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
    """
  return .ok(HTTPResult(statusCode: 200, headers: headers, body: Data(json.utf8)))
}

func errorStep(_ status: Int, headers: [String: String] = [:]) -> ScriptedHTTPExecutor.Step {
  let json = #"{"error":{"message":"boom","type":"server_error"}}"#
  return .ok(HTTPResult(statusCode: status, headers: headers, body: Data(json.utf8)))
}

func decodeBody(_ data: Data) throws -> [String: Any] {
  let object = try JSONSerialization.jsonObject(with: data)
  return try #require(object as? [String: Any])
}

let sampleRequest = ChatRequest(
  model: "gpt-4o",
  messages: [ChatMessage(role: .user, content: "hello")],
  maxOutputTokens: 256
)
