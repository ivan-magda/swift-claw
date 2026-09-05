import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawTestSupport
import Foundation
import Testing

@testable import clawd

/// End-to-end acceptance for the composed fallback: a daemon booted through the **production
/// `RunComposition`** over a config that names a second route, the health rows that report it, and
/// the wire proof that the fallback's traffic carries the fallback's endpoint and its own key.
@Suite("Fallback composition acceptance")
struct FallbackCompositionAcceptanceTests {
  @Test("a daemon with a fallback configured boots with a two-route roster")
  func bootsWithFallback() async throws {
    // given
    var env = CompositionAcceptanceHarness.validEnv()
    env[AcceptanceEnv.fallbackModel] = "gpt-5.4"
    env[AcceptanceEnv.fallbackBaseURL] = "https://fallback.example/v1"

    // when
    let harness = try await CompositionAcceptanceHarness.boot(environment: env)

    // then
    #expect(harness.rosterStack.roster.hasFallback == true)
    #expect(harness.rosterStack.credentialSources.count == 2)
    #expect(harness.healthRow("llm.fallback_configured") == "yes (gpt-5.4)")
    #expect(harness.healthRow("llm.active_route") == "gpt-4o")
    #expect(harness.healthRow("llm.primary_cooldown_s") == "none")
  }

  @Test("a daemon with no fallback configured boots on one route and reports it")
  func bootsWithoutFallback() async throws {
    // given
    let env = CompositionAcceptanceHarness.validEnv()

    // when
    let harness = try await CompositionAcceptanceHarness.boot(environment: env)

    // then — one route, one credential source, and no fallback claimed anywhere
    #expect(harness.rosterStack.roster.hasFallback == false)
    #expect(harness.rosterStack.credentialSources.count == 1)
    #expect(harness.healthRow("llm.fallback_configured") == "no")
    #expect(harness.healthRow("llm.active_route") == "gpt-4o")
  }

  @Test("an armed primary window surfaces on the daemon's own health rows")
  func armedWindowSurfacesInHealthRows() async throws {
    // given — a booted two-route daemon
    var env = CompositionAcceptanceHarness.validEnv()
    env[AcceptanceEnv.fallbackModel] = "gpt-5.4"
    env[AcceptanceEnv.fallbackBaseURL] = "https://fallback.example/v1"
    env[AcceptanceEnv.primaryCooldownSeconds] = "600"
    let harness = try await CompositionAcceptanceHarness.boot(environment: env)

    // when — the shared cooldown the daemon injected into both surfaces arms the primary
    await harness.cooldown.arm(persistence: .long, retryAfterSeconds: nil)
    let rows = await harness.freshHealthRows()

    // then — the window is the configured one (counted down on a real clock, so the last whole
    // second may already have elapsed), and the fallback is named as what answers next
    let remaining = try #require(rows["llm.primary_cooldown_s"].flatMap(Int.init))
    #expect(remaining > 590 && remaining <= 600)
    #expect(rows["llm.active_route"] == "gpt-5.4 (primary gpt-4o cooling)")
  }

  @Test("the shutdown bundle carries every route's credential source, primary first")
  func credentialSourcesAreOrderedPrimaryFirst() async throws {
    // given — a managed primary behind a static-bearer fallback, so the two sources are
    // distinguishable by type and their order is a fact rather than a promise
    var env = CompositionAcceptanceHarness.validEnv()
    env[AppConfig.EnvKey.llmModel] = CompositionAcceptance.qualifiedModel
    env[AcceptanceEnv.fallbackModel] = "gpt-4o"
    env[AcceptanceEnv.fallbackBaseURL] = "https://fallback.example/v1"

    // when
    let harness = try await CompositionAcceptanceHarness.boot(environment: env)

    // then — the shutdown sequence's input holds both, primary first: only the fallback's is the
    // static-bearer source, so the managed one can only be the head of the list
    let sources = harness.bundle.credentialSources
    #expect(sources.count == 2)
    #expect(sources.first is StaticLLMCredentialSource == false)
    #expect(sources.last is StaticLLMCredentialSource)
  }

  @Test("an unbuildable fallback fails the boot")
  func unbuildableFallbackFailsBoot() async throws {
    // given a fallback model that resolves OpenAI-compatible with no base URL
    var env = CompositionAcceptanceHarness.validEnv()
    env[AcceptanceEnv.fallbackModel] = "gpt-5.4"

    // when / then
    await #expect(throws: ConfigError.missingLLMFallbackBaseURL) {
      _ = try await CompositionAcceptanceHarness.boot(environment: env)
    }
  }

  @Test("the fallback request carries its own endpoint and key")
  func fallbackRequestUsesItsOwnWire() async throws {
    // given — a daemon whose primary is the managed ChatGPT route and whose fallback is a
    // configured OpenAI-compatible endpoint with a key of its own
    var env = CompositionAcceptanceHarness.validEnv()
    env[AppConfig.EnvKey.llmModel] = CompositionAcceptance.qualifiedModel
    env[AcceptanceEnv.fallbackModel] = "gpt-4o"
    env[AcceptanceEnv.fallbackBaseURL] = FallbackWire.baseURL
    let harness = try await CompositionAcceptanceHarness.boot(
      environment: env,
      secrets: FallbackWire.secrets
    )

    // given — a transport that walls the plan off on the primary's endpoint and answers on the
    // fallback's, and the production roster composed over it
    let http = ScriptedHTTPExecutor([
      FallbackWire.quotaExhausted,
      .ok(FallbackWire.okCompletion),
    ])
    let rosterStack = try harness.builder.makeRosterStack(http: http)
    let runtime = FallbackWire.makeRuntime(
      roster: rosterStack.roster,
      cooldown: harness.cooldown,
      stores: harness.stores
    )

    // when — one turn runs
    let outcome = try await runtime.runTurn(
      runId: 1,
      sessionId: 1,
      chatId: 1,
      buildResult: BuildResult(
        messages: [ChatMessage(role: .user, content: "what time is it?")],
        ownerNotices: [],
        hasPrivateDataAccess: false
      ),
      sessionTainted: false,
      hasPinnedLessons: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0
    )

    // then — the turn was answered by the fallback, on the fallback's own wire
    guard case .completed(let content, _, _) = outcome.result else {
      Issue.record("expected the fallback to answer, got \(outcome.result)")
      return
    }
    #expect(content == "It is noon.")
    #expect(
      outcome.routeNotice == .switched(from: CompositionAcceptance.qualifiedModel, to: "gpt-4o")
    )

    let recorded = await http.recorded
    let last = try #require(recorded.last)
    #expect(last.url.hasPrefix(FallbackWire.baseURL))
    #expect(last.headers["Authorization"] == "Bearer \(FallbackWire.fallbackKey)")

    // then — every earlier request went to the primary's endpoint under the primary's credential,
    // so the two routes never shared a wire
    let earlier = recorded.dropLast()
    #expect(earlier.isEmpty == false)
    #expect(earlier.allSatisfy { request in request.url == FallbackWire.chatGPTURL })
    #expect(
      earlier.allSatisfy { request in request.headers["Authorization"] == "Bearer acc-token" }
    )
  }
}

// MARK: - Wire Fixtures

/// The two-endpoint scripting the wire test drives: a ChatGPT primary that reports an exhausted
/// plan on every attempt, and an OpenAI-compatible fallback that answers.
private enum FallbackWire {
  static let baseURL = "https://fallback.example/v1"
  static let chatCompletionsURL = baseURL + "/chat/completions"
  static let chatGPTURL = "https://chatgpt.com/backend-api/codex/responses"
  static let fallbackKey = "sk-fallback-key"

  static var secrets: Secrets {
    Secrets(
      telegramBotToken: "token",
      llmApiKey: "sk-primary-key",
      searchApiKey: nil,
      llmFallbackApiKey: fallbackKey
    )
  }

  /// A clean throttle head: the plan is out, nothing was generated. `retry-after: 0` keeps the
  /// adapter's own retry pacing instant so the test spends no wall-clock proving the switch.
  static var quotaExhausted: ScriptedHTTPExecutor.Step {
    .stream(
      HTTPStreamHead(statusCode: 429, headers: ["retry-after": "0"]),
      [Data(#"{"error":{"code":"usage_limit_reached","message":"plan exhausted"}}"#.utf8)]
    )
  }

  static var okCompletion: HTTPResult {
    let json = """
      {"id":"cmpl-1","choices":[{"index":0,"message":{"role":"assistant","content":"It is noon."},\
      "finish_reason":"stop"}],\
      "usage":{"prompt_tokens":9,"completion_tokens":4,"total_tokens":13}}
      """
    return HTTPResult(statusCode: 200, headers: [:], body: Data(json.utf8))
  }

  /// The turn runtime over the composed roster. Typing and drafts are doubles because the wire
  /// under test is the LLM one; everything that decides which endpoint and which key is production.
  static func makeRuntime(
    roster: ProviderRoster,
    cooldown: any PrimaryRouteCooldownTracking,
    stores: ClawStores
  ) -> AgentRuntime {
    AgentRuntime(
      roster: roster,
      cooldown: cooldown,
      typingIndicator: NoopTyping(),
      draftStreamer: NoopRichDraftStreaming(),
      streamingEnabled: false,
      costResolver: CostResolver(
        priceTable: .empty,
        referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
      ),
      budget: .default,
      usageStore: stores.usage,
      auditLog: stores.audit,
      clock: ContinuousClock()
    )
  }
}
