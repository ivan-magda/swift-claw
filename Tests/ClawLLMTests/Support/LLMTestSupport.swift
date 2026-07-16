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

/// Plays back a scripted queue of HTTP outcomes and records every request it received, so retry
/// counts, request shaping, and header handling can be asserted. It holds the seam's contract rather
/// than shortcutting it: the body policy must match the entry point, the handoff runs once before
/// the scripted answer, and a scripted stream is an owning exchange with the same bound the real
/// executor would give it.
actor ScriptedHTTPExecutor: HTTPExecuting, HTTPStreaming {
  enum Step: Sendable {
    case ok(HTTPResult)
    case fail(TransportFailure)
    case stream(HTTPStreamHead, [Data])
    case streamFailure(HTTPStreamHead, [Data], TransportFailure)
    /// A typed transport failure with the disposition under test. Tests state the disposition; they
    /// never leave it to be guessed from the message.
    case transportFailure(HTTPTransportFailure)
    /// Chunks the producer may not send until the gate opens, so a test can hold a stream open and
    /// watch what its consumer does meanwhile. Always pair it with a `defer { gate.open() }`.
    case blockedStream(HTTPStreamHead, [Data], AsyncGate)
  }

  struct Recorded: Sendable {
    let url: String
    let headers: [String: String]
    let body: Data
    let timeoutSeconds: Int
    let responseBodyPolicy: HTTPResponseBodyPolicy
    let handoffCount: Int
  }

  private var steps: [Step]
  private(set) var recorded: [Recorded] = []

  init(_ steps: [Step]) {
    self.steps = steps
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    guard case .buffered = request.responseBodyPolicy else {
      throw HTTPTransportFailure(
        disposition: .definitelyNotSent,
        safeMessage: "execute needs a buffered response body policy"
      )
    }
    try begin(request)

    guard !steps.isEmpty else {
      throw TransportFailure(message: "scripted executor exhausted")
    }
    switch steps.removeFirst() {
    case .ok(let result): return result
    case .fail(let error): throw error
    case .transportFailure(let failure): throw failure
    case .stream, .streamFailure, .blockedStream:
      throw TransportFailure(message: "expected buffered step, got streaming step")
    }
  }

  func openStream(_ request: HTTPRequest) async throws -> HTTPStreamExchange {
    guard case .streaming(let maximumUnreadBytes, let errorBytes) = request.responseBodyPolicy
    else {
      throw HTTPTransportFailure(
        disposition: .definitelyNotSent,
        safeMessage: "openStream needs a streaming response body policy"
      )
    }
    try begin(request)

    guard !steps.isEmpty else {
      throw HTTPTransportFailure(
        disposition: .mayHaveBeenSent,
        safeMessage: "scripted executor exhausted"
      )
    }
    switch steps.removeFirst() {
    case .transportFailure(let failure):
      throw failure
    case .stream(let head, let chunks):
      return Self.exchange(
        head: head,
        chunks: chunks,
        unread: maximumUnreadBytes,
        error: errorBytes
      )
    case .streamFailure(let head, let chunks, let failure):
      return Self.exchange(
        head: head,
        chunks: chunks,
        unread: maximumUnreadBytes,
        error: errorBytes,
        failure: HTTPTransportFailure(
          disposition: .mayHaveBeenSent,
          safeMessage: failure.message
        )
      )
    case .blockedStream(let head, let chunks, let gate):
      return Self.exchange(
        head: head,
        chunks: chunks,
        unread: maximumUnreadBytes,
        error: errorBytes,
        gate: gate
      )
    case .ok, .fail:
      throw HTTPTransportFailure(
        disposition: .mayHaveBeenSent,
        safeMessage: "expected streaming step, got buffered step"
      )
    }
  }

  /// Runs the call's handoff and then, only if it let the attempt through, records the call — the
  /// order the real executor takes. `recorded` is read as what was dispatched, so a refused attempt
  /// must leave no trace of a dispatch that never happened.
  private func begin(_ request: HTTPRequest) throws {
    let tally = HandoffTally()
    try tally.run(request.beginHandoff)
    recorded.append(
      Recorded(
        url: request.url,
        headers: request.headers,
        body: request.body ?? Data(),
        timeoutSeconds: request.timeoutSeconds,
        responseBodyPolicy: request.responseBodyPolicy,
        handoffCount: tally.value
      )
    )
  }

  private static func exchange(
    head: HTTPStreamHead,
    chunks: [Data],
    unread: Int,
    error: Int,
    failure: HTTPTransportFailure? = nil,
    gate: AsyncGate? = nil
  ) -> HTTPStreamExchange {
    HTTPStreamExchange.make(
      head: head,
      maximumUnreadBodyBytes: (200..<300).contains(head.statusCode) ? unread : error
    ) { sink in
      if let gate {
        await gate.waitIgnoringCancellation()
      }
      do {
        for chunk in chunks {
          try await sink.send(chunk)
        }
      } catch {
        return .cancelled(.mayHaveBeenSent)
      }
      if let failure {
        return .failed(failure)
      }
      return .completed
    }
  }
}

/// Offers exactly the headers and redaction values a test names. `StaticLLMCredentialSource` can
/// only ever offer `Authorization`, so it cannot drive the adapter's header allowlist at all — that
/// is precisely what this double exists to reach.
struct ScriptedLLMCredentialSource: LLMCredentialSource {
  var headers: [String: String] = [:]
  var redactionValues: [String] = []
  var failure: (any Error)?

  func authorization() async throws -> LLMRequestAuthorization {
    if let failure {
      throw failure
    }
    return LLMRequestAuthorization(
      headers: headers,
      redactionValues: redactionValues,
      generation: .zero
    )
  }

  func reject(
    generation: LLMCredentialGeneration,
    disposition: LLMCredentialRejection
  ) async {}

  func shutdown() async throws {}
}

/// A credential-source error, to prove no request goes out when authorization cannot be resolved.
struct CredentialUnavailable: Error {}

/// Records the delays the provider asks to sleep for, so `Retry-After` honoring is observable.
actor SleepRecorder {
  private(set) var delays: [Double] = []

  func record(_ seconds: Double) {
    delays.append(seconds)
  }
}

// MARK: - Builders

/// Resolves a current-route `LLMConfig` for a configured endpoint. The wire endpoint and the
/// output-token field ride alongside it — the reshaped `LLMConfig` carries neither — so `makeProvider`
/// can hand the adapter the same three values composition does.
struct TestProviderConfig {
  let config: LLMConfig
  let endpoint: String
  let maxTokensField: MaxTokensField
  let apiKey: String
}

/// A current-route resolution for a configured endpoint, so a test needing only the wire adapter does
/// not restate the descriptor.
func makeCurrentRoute(
  endpoint: String = "https://api.test/v1",
  model: String = "gpt-4o"
) -> ResolvedLLMRoute {
  ResolvedLLMRoute(
    descriptor: .openAICompatible(endpoint: endpoint),
    configuredReference: model,
    wireModel: model
  )
}

func makeConfig(
  baseURL: String = "https://api.test/v1",
  maxTokensField: MaxTokensField = .maxCompletionTokens,
  apiKey: String = "sk-test",
  model: String = "gpt-4o",
  maxOutputTokens: Int = 256,
  retryBudget: Int = 3
) -> TestProviderConfig {
  TestProviderConfig(
    config: LLMConfig(
      route: makeCurrentRoute(endpoint: baseURL, model: model),
      maxOutputTokens: maxOutputTokens,
      retryBudget: retryBudget,
      requestTimeoutSeconds: 30
    ),
    endpoint: baseURL,
    maxTokensField: maxTokensField,
    apiKey: apiKey
  )
}

/// Defaults the credential source to the static one composition uses, seeded from the config's key,
/// so a test that only cares about wire shaping still authorizes exactly the way production does.
func makeProvider(
  config: TestProviderConfig,
  http: any HTTPExecuting & HTTPStreaming,
  credentials: (any LLMCredentialSource)? = nil,
  recorder: SleepRecorder = SleepRecorder(),
  jitter: @escaping @Sendable (Duration) -> Duration = { _ in .zero }
) -> OpenAICompatibleProvider {
  OpenAICompatibleProvider(
    config: config.config,
    endpoint: config.endpoint,
    maxTokensField: config.maxTokensField,
    credentials: credentials ?? StaticLLMCredentialSource(bearer: config.apiKey),
    http: http,
    clock: ScriptedClock { delay in
      await recorder.record(delay / .seconds(1))
    },
    jitter: jitter
  )
}

/// Drains a session and joins it, the way every consumer must. Returns the events and the terminal
/// so a test can assert on both without repeating the join.
func drain(
  _ stream: LLMEventStream
) async -> (events: [StreamEvent], thrown: (any Error)?, terminal: LLMStreamTermination) {
  var events: [StreamEvent] = []
  var thrown: (any Error)?
  do {
    for try await event in stream {
      events.append(event)
    }
  } catch {
    thrown = error
  }
  return (events, thrown, await stream.awaitTermination())
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
