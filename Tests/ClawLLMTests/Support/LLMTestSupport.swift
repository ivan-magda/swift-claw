import ClawTestSupport
import Foundation
import Testing

@testable import ClawCore
@testable import ClawLLM

// MARK: - Test doubles

/// A credential store whose one behavior a test scripts: a present record, an absent one (logged
/// out), or a typed store failure. It records whether it was opened at all, so the current route can
/// be proven never to touch it.
final class ScriptedCredentialStore: LLMCredentialStore, @unchecked Sendable {
  enum Behavior: Sendable {
    case value(StoredOAuthCredential?)
    case failure(LLMCredentialStoreError)
  }

  let behavior: Behavior
  private(set) var loadCount = 0

  init(_ behavior: Behavior) {
    self.behavior = behavior
  }

  func load(providerID: LLMProviderID) throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    loadCount += 1
    switch behavior {
    case .value(let credential):
      return credential
    case .failure(let error):
      throw error
    }
  }

  func save(
    _ credential: StoredOAuthCredential,
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) {}

  func delete(providerID: LLMProviderID) throws(LLMCredentialStoreError) {}
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

/// The managed ChatGPT route, so a test needing only the Responses adapter's shape does not restate
/// the qualified descriptor.
func chatGPTRoute() -> ResolvedLLMRoute {
  ResolvedLLMRoute(
    descriptor: .openAIChatGPT,
    configuredReference: "openai-chatgpt/gpt-5.4",
    wireModel: "gpt-5.4"
  )
}

/// An unexpired stored ChatGPT credential, so a managed-route composition test can authorize without
/// opening a refresh flight.
func storedCredential() -> StoredOAuthCredential {
  StoredOAuthCredential(
    profileID: UUID(),
    accessToken: "access-token",
    refreshToken: "refresh-token",
    expiresAt: Date().addingTimeInterval(3600)
  )
}

/// The `LLMConfig` a resolved route composes against, holding every other setting fixed.
func settings(route: ResolvedLLMRoute, retryBudget: Int = 3) -> LLMConfig {
  LLMConfig(route: route, maxOutputTokens: 256, retryBudget: retryBudget, requestTimeoutSeconds: 30)
}

/// A static-bearer route carrying an arbitrary egress, to reach the current-route composition path
/// with a shape a registered descriptor never produces — a registry defect, not configuration.
func currentRouteWithEgress(_ egress: LLMEgressIdentity) -> ResolvedLLMRoute {
  ResolvedLLMRoute(
    descriptor: LLMProviderDescriptor(
      providerID: .openAICompatible,
      qualifiedPrefix: nil,
      egress: egress,
      credentialMode: .noneOrStaticBearer,
      capabilities: LLMProviderCapabilities(
        supportsStructuredOutput: true,
        outputTokenField: .configured(.maxCompletionTokens)
      )
    ),
    configuredReference: "gpt-4o",
    wireModel: "gpt-4o"
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

/// The shortest body `ImageMediaType.sniff` accepts as a JPEG, so both wire adapters' image tests
/// assert the same bytes reach the model.
let samplePixel = ImagePart(
  data: Data([0xFF, 0xD8, 0xFF, 0xE0]),
  mediaType: .jpeg,
  width: 1280,
  height: 960
)

/// The bytes a `data:` URL carries behind `prefix`. A test that stops at the prefix passes just as
/// happily on an empty payload, which is the one failure the encoders must never ship.
func decodedImageBytes(after prefix: String, of dataURL: String) throws -> Data {
  try #require(dataURL.hasPrefix(prefix))
  return try #require(Data(base64Encoded: String(dataURL.dropFirst(prefix.count))))
}
