import AsyncHTTPClient
import ClawCore
import ClawData
import ClawLLM
import ClawTelegram
import ClawTestSupport
import Foundation
import GRDB

/// A scripted `HTTPExecuting & HTTPStreaming` double for the composition acceptance suites. It records
/// every request (so the fixed endpoint, headers, and wire body are assertable) and answers each
/// `openStream` from a queue of SSE scripts. A `gate` variant parks the producer inside the body
/// transfer so a lane can be held live across a shutdown.
actor AcceptanceStreamingHTTP: HTTPExecuting, HTTPStreaming {
  /// Parks the body producer live inside the exchange: it opens `started` on entry (so a test knows
  /// the lane is running inside provider SSE and nested HTTP), then waits on `release` before it may
  /// finish. Ignoring cancellation is deliberate — the join must outlive a cancel, which is the exact
  /// grace-timeout condition under test.
  struct StreamHold: Sendable {
    let started: AsyncGate
    let release: AsyncGate

    init(started: AsyncGate = AsyncGate(), release: AsyncGate = AsyncGate()) {
      self.started = started
      self.release = release
    }
  }

  struct StreamScript: Sendable {
    let head: HTTPStreamHead
    let chunks: [Data]
    let hold: StreamHold?

    init(head: HTTPStreamHead, chunks: [Data], hold: StreamHold? = nil) {
      self.head = head
      self.chunks = chunks
      self.hold = hold
    }
  }

  struct Recorded: Sendable {
    let url: String
    let headers: [String: String]
    let body: Data?
  }

  private var streamScripts: [StreamScript]
  private let bufferedResponses: [String: HTTPResult]
  private(set) var recorded: [Recorded] = []

  init(streamScripts: [StreamScript], bufferedResponses: [String: HTTPResult] = [:]) {
    self.streamScripts = streamScripts
    self.bufferedResponses = bufferedResponses
  }

  var requestedURLs: [String] { recorded.map(\.url) }
  var lastBody: Data? { recorded.last?.body }
  var lastHeaders: [String: String] { recorded.last?.headers ?? [:] }

  func execute(_ request: HTTPRequest) async throws -> HTTPResult {
    try request.beginHandoff?()
    recorded.append(Recorded(url: request.url, headers: request.headers, body: request.body))
    guard let scripted = bufferedResponses[request.url] else {
      throw UnscriptedAcceptanceRequest(url: request.url)
    }
    return scripted
  }

  func openStream(_ request: HTTPRequest) async throws -> HTTPStreamExchange {
    try request.beginHandoff?()
    recorded.append(Recorded(url: request.url, headers: request.headers, body: request.body))
    guard !streamScripts.isEmpty else {
      throw UnscriptedAcceptanceRequest(url: request.url)
    }
    let script = streamScripts.removeFirst()
    return HTTPStreamExchange.make(
      head: script.head,
      maximumUnreadBodyBytes: HTTPResponseBodyPolicy.maximumUnreadStreamBytes,
      operation: { sink in
        if let hold = script.hold {
          hold.started.open()
          await hold.release.waitIgnoringCancellation()
        }
        for chunk in script.chunks {
          try? await sink.send(chunk)
        }
        return .completed
      }
    )
  }
}

/// An unmatched URL is a test defect, so the scripted transport refuses it loudly.
struct UnscriptedAcceptanceRequest: Error {
  let url: String
}

// MARK: - Fixed fresh credential

/// A managed store that hands back one fresh credential (far-future expiry, so the source never
/// refreshes) and records how many times it was opened — the load-count proof.
final class FreshCredentialStore: LLMCredentialStore, @unchecked Sendable {
  static let profileID = UUID(uuid: (0xCE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
  private let outcome: Result<StoredOAuthCredential?, LLMCredentialStoreError>
  private let lock = NSLock()
  private var loads = 0

  init(present: Bool = true) {
    outcome = .success(
      present
        ? StoredOAuthCredential(
          profileID: Self.profileID,
          accessToken: "acc-token",
          refreshToken: "ref-token",
          expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        : nil
    )
  }

  /// A store whose `load` throws — the managed-store failure a boot must propagate and close every
  /// client on.
  init(failure: LLMCredentialStoreError) {
    outcome = .failure(failure)
  }

  var loadCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return loads
  }

  func load(providerID: LLMProviderID) throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    lock.lock()
    loads += 1
    lock.unlock()
    switch outcome {
    case .success(let credential):
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

// MARK: - Composition

enum CompositionAcceptance {
  static let qualifiedModel = "openai-chatgpt/gpt-5.4"
  static let wireModel = "gpt-5.4"

  /// The ChatGPT route as production resolves it from `CLAW_LLM_MODEL`, plus its `LLMConfig`.
  static func chatGPTConfig() throws -> AppConfig {
    let root = NSTemporaryDirectory() + "clawd-acc-" + UUID().uuidString
    return try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: root,
      AppConfig.EnvKey.llmModel: qualifiedModel,
    ])
  }

  /// Builds the real provider stack through the **production `ProviderStackFactory`** over a scripted
  /// transport and a fresh managed credential — no hand-built provider.
  static func makeStack(
    http: AcceptanceStreamingHTTP,
    store: any LLMCredentialStore
  ) throws -> ProviderStack {
    let config = try chatGPTConfig()
    return try ProviderStackFactory.make(
      route: config.llm.route,
      settings: config.llm,
      loadStaticBearer: { nil },
      makeManagedCredentialStore: { store },
      http: http,
      buildVersion: "acc-1.0.0"
    )
  }

  // MARK: SSE fixtures (one `data:` frame per event)

  static func event(_ json: String) -> Data { Data("data: \(json)\n\n".utf8) }

  static let okHead = HTTPStreamHead(statusCode: 200, headers: [:])

  /// A clean head rejection naming poisoned replay state — the trigger for a state-free retry that
  /// marks a fresh epoch. The body is a plain diagnostic (not an SSE frame), as a non-2xx head sends.
  static let invalidEncryptedContentHead = HTTPStreamHead(statusCode: 400, headers: [:])

  static func invalidEncryptedContentBody() -> [Data] {
    [Data(#"{"error":{"code":"invalid_encrypted_content","message":"bad state"}}"#.utf8)]
  }

  /// A tool-round reply: visible text, encrypted reasoning replay material, and one function call.
  static func toolRound(callID: String, tokens: (input: Int, output: Int)) -> [Data] {
    [
      event(
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
      ),
      event(
        #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Let me check."}]}}"#
      ),
      event(
        #"{"type":"response.output_item.added","output_index":1,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"ENC-A"}}"#
      ),
      event(
        #"{"type":"response.output_item.done","output_index":1,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"ENC-A"}}"#
      ),
      event(
        #"{"type":"response.output_item.added","output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"\#(callID)","name":"clock"}}"#
      ),
      event(
        #"{"type":"response.output_item.done","output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"\#(callID)","name":"clock","arguments":"{}"}}"#
      ),
      completed(tokens: tokens),
    ]
  }

  /// A terminal reply: visible final text and usage, no tool call.
  static func terminalRound(tokens: (input: Int, output: Int)) -> [Data] {
    [
      event(
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","status":"in_progress"}}"#
      ),
      event(
        #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"It is noon."}]}}"#
      ),
      completed(tokens: tokens),
    ]
  }

  static func completed(tokens: (input: Int, output: Int)) -> Data {
    event(
      #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":\#(tokens.input),"output_tokens":\#(tokens.output),"total_tokens":\#(tokens.input + tokens.output)}}}"#
    )
  }

  // MARK: GRDB

  static func makeStores() throws -> (
    writer: any DatabaseWriter,
    sessions: SessionMessageStoreGRDB,
    runs: RunStoreGRDB,
    usage: UsageStoreGRDB
  ) {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return (
      queue,
      SessionMessageStoreGRDB(writer: queue),
      RunStoreGRDB(writer: queue),
      UsageStoreGRDB(writer: queue)
    )
  }
}

// MARK: - Shutdown doubles

/// Thrown by a substitute process terminator in place of the production `_exit`, so a test can prove
/// control left through `terminate()` without ending the test process itself.
struct FatalExitSentinel: Error {}

/// A lock-guarded box for the exit code a substitute terminator recorded.
final class ExitCodeBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Int32?

  var value: Int32? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ code: Int32) {
    lock.lock()
    defer { lock.unlock() }
    stored = code
  }
}

// MARK: - Composition doubles

/// Records the order runtime HTTP clients are closed in, so a failed boot can be proven to leak none.
actor CloseRecorder {
  private(set) var order: [RuntimeHTTPClientRole] = []

  func record(_ role: RuntimeHTTPClientRole) {
    order.append(role)
  }
}

/// Captures the one provider stack the assembler received, so a test reads the resolved route without
/// standing up a real daemon.
final class StackBox: @unchecked Sendable {
  var stack: ProviderStack?
}

/// The runtime HTTP clients wired to real per-role `HTTPClient`s, each of which records its role on
/// `recorder` as it closes — so a boot-failure test can prove every client was shut down, and in what
/// order.
func instrumentedClients(recorder: CloseRecorder) -> RuntimeHTTPClients<RuntimeHTTPClient> {
  RuntimeHTTPClients { role in
    let client = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: role.egressProfile.configuration
    )
    return RuntimeHTTPClient(
      executor: AsyncHTTPExecutor(client: client),
      close: {
        await recorder.record(role)
        try await client.shutdown()
      }
    )
  }
}
