import AsyncHTTPClient
import ClawCore
import ClawGateway
import ClawLLM
import ClawTelegram
import Foundation
import Logging
import Testing

@testable import clawd

// MARK: - Doubles

/// Stops a composition test before the heavy daemon assembly, so what reached the assembler — and
/// that every client was closed afterward — is all the test has to observe.
private struct BuildStopped: Error {}

/// Records the order clients are closed in, proving a failed boot leaks none.
private actor CloseRecorder {
  private(set) var order: [RuntimeHTTPClientRole] = []

  func record(_ role: RuntimeHTTPClientRole) {
    order.append(role)
  }
}

/// Captures the one provider stack the assembler received, so a test reads the route the factory
/// resolved without a real daemon.
private final class StackBox: @unchecked Sendable {
  var stack: ProviderStack?
}

/// Flips when the managed-store factory is built, so the current route can be proven never to open an
/// OAuth envelope.
private final class InvocationFlag: @unchecked Sendable {
  private(set) var invoked = false

  func mark() { invoked = true }
}

/// A managed store whose one behavior a test scripts, counting loads.
private final class StoreProbe: LLMCredentialStore, @unchecked Sendable {
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

@Suite struct ProviderCompositionTests {
  private static let baseURLKey = "CLAW_LLM_BASE_URL"

  private func config(model: String, baseURL: String?) throws -> AppConfig {
    let root = NSTemporaryDirectory() + "clawd-composition-" + UUID().uuidString
    var env = [
      AppConfig.EnvKey.stateRoot: root,
      AppConfig.EnvKey.llmModel: model,
    ]
    if let baseURL {
      env[Self.baseURLKey] = baseURL
    }
    return try AppConfig.load(environment: env)
  }

  private var silentLogger: Logger {
    Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })
  }

  private func instrumentedClients(
    recorder: CloseRecorder
  ) -> RuntimeHTTPClients<RuntimeHTTPClient> {
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

  private func composition(
    config: AppConfig,
    recorder: CloseRecorder,
    makeManagedStore: @escaping @Sendable (URL) -> any LLMCredentialStore,
    buildDaemon:
      @escaping @Sendable (DaemonBuilder, ProviderStack) async throws ->
      DaemonRuntimeBundle
  ) throws -> RunComposition {
    var composition = RunComposition(
      config: config,
      secrets: Secrets(telegramBotToken: "token", llmApiKey: "sk-static", searchApiKey: nil),
      stores: try EnvironmentLoader.openStores(config: config),
      logger: silentLogger
    )
    composition.makeClients = { self.instrumentedClients(recorder: recorder) }
    composition.makeManagedStore = makeManagedStore
    composition.fetchBotUsername = { _, _ in nil }
    composition.buildDaemon = buildDaemon
    return composition
  }

  @Test func currentRouteOpensNoEnvelopeAndClosesAllOnFailure() async throws {
    // given — the current route, an assembler that stops after capturing the resolved stack, and a
    // managed-store factory that must never be built
    let recorder = CloseRecorder()
    let storeBuilt = InvocationFlag()
    let box = StackBox()
    let composition = try composition(
      config: config(model: "gpt-4o", baseURL: "https://api.test/v1"),
      recorder: recorder,
      makeManagedStore: { _ in
        storeBuilt.mark()
        return StoreProbe(.value(nil))
      },
      buildDaemon: { _, stack in
        box.stack = stack
        throw BuildStopped()
      }
    )

    // when / then — the assembler ran (so the resolved route reached the factory), the build failed,
    // and the failure closed every client
    await #expect(throws: BuildStopped.self) {
      try await composition.compose()
    }
    #expect(storeBuilt.invoked == false)
    #expect(box.stack?.costPolicy == .metered)
    #expect(box.stack?.configuredReference == "gpt-4o")
    #expect(await recorder.order == [.llm, .telegram, .tool])
  }

  @Test func chatGPTMalformedEnvelopePropagatesAndClosesAll() async throws {
    // given — the managed route with a malformed envelope; assembly must never be reached
    let recorder = CloseRecorder()
    let composition = try composition(
      config: config(model: "openai-chatgpt/gpt-5.4", baseURL: nil),
      recorder: recorder,
      makeManagedStore: { _ in StoreProbe(.failure(.malformedStorage)) },
      buildDaemon: { _, _ in
        Issue.record("assembly must not run when the stack build fails")
        throw BuildStopped()
      }
    )

    // when / then — the closed store taxonomy propagates (RunCommand maps it to the secret-load exit
    // code), and every already-created client is closed
    await #expect(throws: LLMCredentialStoreError.malformedStorage) {
      try await composition.compose()
    }
    #expect(await recorder.order == [.llm, .telegram, .tool])
  }
}
