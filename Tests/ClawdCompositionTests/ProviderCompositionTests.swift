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

/// Flips when the managed-store factory is built, so the current route can be proven never to open an
/// OAuth envelope.
private final class InvocationFlag: @unchecked Sendable {
  private(set) var invoked = false

  func mark() { invoked = true }
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

  private func composition(
    config: AppConfig,
    recorder: CloseRecorder,
    makeManagedStore: @escaping @Sendable (URL) -> any LLMCredentialStore,
    buildDaemon:
      @escaping @Sendable (DaemonBuilder, RosterStack, PrimaryRouteCooldown<ContinuousClock>)
      async throws
      -> DaemonRuntimeBundle
  ) throws -> RunComposition {
    var composition = RunComposition(
      config: config,
      secrets: Secrets(telegramBotToken: "token", llmApiKey: "sk-static", searchApiKey: nil),
      stores: try EnvironmentLoader.openStores(config: config),
      logger: silentLogger
    )
    composition.makeClients = { instrumentedClients(recorder: recorder) }
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
        return FreshCredentialStore(present: false)
      },
      buildDaemon: { _, stack, _ in
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
    #expect(box.stack?.roster.primary.costPolicy == .metered)
    #expect(box.stack?.roster.primary.configuredReference == "gpt-4o")
    #expect(box.stack?.roster.hasFallback == false)
    #expect(await recorder.order == [.llm, .telegram, .tool])
  }

  @Test func chatGPTMalformedEnvelopePropagatesAndClosesAll() async throws {
    // given — the managed route with a malformed envelope; assembly must never be reached
    let recorder = CloseRecorder()
    let composition = try composition(
      config: config(model: "openai-chatgpt/gpt-5.4", baseURL: nil),
      recorder: recorder,
      makeManagedStore: { _ in FreshCredentialStore(failure: .malformedStorage) },
      buildDaemon: { _, _, _ in
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
