import AsyncHTTPClient
import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawTelegram
import ClawTestSupport
import Foundation
import GRDB
import Logging

@testable import clawd

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
    http: ScriptedHTTPExecutor,
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

  static func makeBuilder(
    http: any HTTPExecuting & HTTPStreaming,
    config: AppConfig? = nil,
    secrets: Secrets = Secrets(
      telegramBotToken: "tg-token",
      llmApiKey: nil,
      searchApiKey: nil
    ),
    mcp: MCPBootInputs = .empty
  ) throws -> DaemonBuilder {
    let config = try config ?? chatGPTConfig()
    return DaemonBuilder(
      config: config,
      secrets: secrets,
      stores: try EnvironmentLoader.openStores(config: config),
      toolExecutor: http,
      transport: TelegramClient(token: secrets.telegramBotToken, http: http),
      botIdentity: nil,
      mcp: mcp,
      logger: Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() }),
      makeManagedStore: { FreshCredentialStore(present: false) }
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

/// Captures the one roster the assembler received, so a test reads the resolved routes without
/// standing up a real daemon.
final class StackBox: @unchecked Sendable {
  var stack: RosterStack?
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

// MARK: - Booted daemon

/// The environment variables a composition test sets by name. `AppConfig.EnvKey` keeps most of its
/// members internal to `ClawCore`, so this is the one place a test spells the raw variable.
enum AcceptanceEnv {
  static let baseURL = "CLAW_LLM_BASE_URL"
  static let fallbackModel = "CLAW_LLM_FALLBACK_MODEL"
  static let fallbackBaseURL = "CLAW_LLM_FALLBACK_BASE_URL"
  static let primaryCooldownSeconds = "CLAW_LLM_PRIMARY_COOLDOWN_SECONDS"
  static let voiceTranscription = "CLAW_VOICE_TRANSCRIPTION"
}

/// A daemon composed through the **production `RunComposition`**: the real config parse, the real
/// roster factory, the real service graph. It captures the exact roster, cooldown, and builder the
/// assembled daemon runs on, so a test reads what was wired rather than re-deriving it, and answers
/// the health rows through the same reporter the daemon's `/doctor` replies with.
///
/// No socket is opened: the three runtime clients share the process-wide `HTTPClient.shared`
/// (nothing is ever sent through them, and it needs no shutdown) and the bot identity is stubbed.
struct CompositionAcceptanceHarness {
  let config: AppConfig
  let stores: ClawStores
  let builder: DaemonBuilder
  let rosterStack: RosterStack
  let cooldown: PrimaryRouteCooldown<ContinuousClock>
  let bundle: DaemonRuntimeBundle
  private let sandbox: DaemonBuilder.SandboxStack
  private let rows: [String: String]

  /// A configuration that boots: a private state root, the current OpenAI-compatible route, and
  /// voice off so no test reaches for an on-device speech engine.
  static func validEnv() -> [String: String] {
    [
      AppConfig.EnvKey.stateRoot: NSTemporaryDirectory() + "clawd-boot-" + UUID().uuidString,
      AppConfig.EnvKey.llmModel: "gpt-4o",
      AcceptanceEnv.baseURL: "https://primary.example/v1",
      AcceptanceEnv.voiceTranscription: "false",
    ]
  }

  static func boot(
    environment: [String: String],
    secrets: Secrets = Secrets(telegramBotToken: "token", llmApiKey: "sk-static"),
    managedStore: @escaping @Sendable () -> any LLMCredentialStore = { FreshCredentialStore() }
  ) async throws -> CompositionAcceptanceHarness {
    let config = try AppConfig.load(environment: environment)
    let stores = try EnvironmentLoader.openStores(config: config)
    let capture = BootCapture()

    var composition = RunComposition(
      config: config,
      secrets: secrets,
      stores: stores,
      logger: Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })
    )
    composition.makeClients = {
      RuntimeHTTPClients { _ in
        RuntimeHTTPClient(executor: AsyncHTTPExecutor(client: .shared), close: {})
      }
    }
    composition.makeManagedStore = { _ in managedStore() }
    composition.fetchBotIdentity = { _, _ in nil }
    composition.buildDaemon = { builder, rosterStack, cooldown in
      capture.record(builder: builder, rosterStack: rosterStack, cooldown: cooldown)
      return try await RunComposition.assembleDaemon(builder, rosterStack, cooldown)
    }

    let composed = try await composition.compose()
    let builder = try capture.requireBuilder()
    let sandbox = await builder.prepareSandbox()

    return CompositionAcceptanceHarness(
      config: config,
      stores: stores,
      builder: builder,
      rosterStack: try capture.requireRosterStack(),
      cooldown: try capture.requireCooldown(),
      bundle: composed.bundle,
      sandbox: sandbox,
      rows: await Self.healthRows(builder: builder, sandbox: sandbox, capture: capture)
    )
  }

  func healthRow(_ key: String) -> String? { rows[key] }

  /// Re-reads the rows from the same reporter, so a test that changes live state (arming the shared
  /// cooldown, say) sees what the daemon would report now rather than what it reported at boot.
  func freshHealthRows() async -> [String: String] {
    await Self.rowValues(
      builder.makeDoctorReporter(sandbox: sandbox, cooldown: cooldown, mcpOutcomes: [])
    )
  }

  private static func healthRows(
    builder: DaemonBuilder,
    sandbox: DaemonBuilder.SandboxStack,
    capture: BootCapture
  ) async -> [String: String] {
    guard let cooldown = try? capture.requireCooldown() else { return [:] }
    return await rowValues(
      builder.makeDoctorReporter(sandbox: sandbox, cooldown: cooldown, mcpOutcomes: [])
    )
  }

  private static func rowValues(_ reporter: DaemonDoctorReporter) async -> [String: String] {
    let report = await reporter.report()
    return Dictionary(
      report.checks.map { check in (check.key, check.value) },
      uniquingKeysWith: { first, _ in first }
    )
  }
}

/// A boot that never reached the assembler left nothing to read; that is a test defect, so the
/// accessors throw rather than force-unwrap.
struct BootNeverAssembled: Error {}

/// Captures what the production assembler received, so the harness holds the same instances the
/// daemon does instead of building look-alikes.
final class BootCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var builder: DaemonBuilder?
  private var rosterStack: RosterStack?
  private var cooldown: PrimaryRouteCooldown<ContinuousClock>?

  func record(
    builder: DaemonBuilder,
    rosterStack: RosterStack,
    cooldown: PrimaryRouteCooldown<ContinuousClock>
  ) {
    lock.lock()
    defer { lock.unlock() }
    self.builder = builder
    self.rosterStack = rosterStack
    self.cooldown = cooldown
  }

  func requireBuilder() throws -> DaemonBuilder {
    lock.lock()
    defer { lock.unlock() }
    guard let builder else { throw BootNeverAssembled() }
    return builder
  }

  func requireRosterStack() throws -> RosterStack {
    lock.lock()
    defer { lock.unlock() }
    guard let rosterStack else { throw BootNeverAssembled() }
    return rosterStack
  }

  func requireCooldown() throws -> PrimaryRouteCooldown<ContinuousClock> {
    lock.lock()
    defer { lock.unlock() }
    guard let cooldown else { throw BootNeverAssembled() }
    return cooldown
  }
}
