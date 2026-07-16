import AsyncHTTPClient
import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawSecrets
import ClawTelegram
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import clawd

/// End-to-end ChatGPT subscription acceptance: the feature composed through the **production
/// `RunComposition` / `ProviderStackFactory`** (never a hand-built provider), driven over scripted
/// Responses SSE and real GRDB stores. Proves the resolved route, fixed endpoint and headers, wire vs
/// qualified model identities, a multi-turn replay round-trip with a byte-golden for the replayed
/// body, included-plan accounting, and `ProviderCallID` idempotency.
@Suite struct ChatGPTSubscriptionAcceptanceTests {
  private static let responsesURL = "https://chatgpt.com/backend-api/codex/responses"

  // MARK: - Production composition (RunComposition)

  /// The composed stack is the included-plan managed stack, its envelope is opened exactly once
  /// (missing record is a logged-out boot, not a throw), and a failing build closes all **three
  /// distinct** HTTP client identities in order — llm, telegram, tool.
  @Test func chatGPTRouteComposesIncludedPlanStackAndClosesThreeClientsOnFailure() async throws {
    // given
    let recorder = CloseOrderRecorder()
    let store = FreshCredentialStore(present: false)
    let box = ComposedStackBox()
    var composition = try Self.makeComposition(recorder: recorder, store: store)
    composition.buildDaemon = { _, stack in
      box.value = stack
      throw StopBuild()
    }

    // when / then — the build stopped after the stack was resolved, and every client closed
    await #expect(throws: StopBuild.self) {
      _ = try await composition.compose()
    }
    #expect(store.loadCount == 1)
    #expect(box.value?.costPolicy == .includedPlan)
    #expect(box.value?.reservationPolicy == .chatGPTReplayState)
    #expect(box.value?.configuredReference == CompositionAcceptance.qualifiedModel)
    #expect(box.value?.wireModel == CompositionAcceptance.wireModel)
    #expect(await recorder.order == [.llm, .telegram, .tool])
  }

  // MARK: - Composed provider turn over scripted SSE

  /// The composed provider hits only the fixed HTTPS endpoint, carries the pinned Codex-CLI headers
  /// and the credential bearer, and sends the **unqualified** wire model — while the stack keeps the
  /// qualified reference for accounting.
  @Test func composedProviderUsesFixedEndpointPinnedHeadersAndWireModel() async throws {
    // given
    let http = AcceptanceStreamingHTTP(streamScripts: [
      .init(
        head: CompositionAcceptance.okHead,
        chunks: CompositionAcceptance.terminalRound(tokens: (5, 2))
      )
    ])
    let stack = try CompositionAcceptance.makeStack(http: http, store: FreshCredentialStore())

    // when
    let response = try await stack.provider.complete(
      request: ChatRequest(
        model: stack.wireModel,
        messages: [ChatMessage(role: .user, content: "what time is it?")],
        maxOutputTokens: 256,
        sessionId: "sess-acc"
      )
    )

    // then — the route identities are distinct and the wire hit the fixed endpoint
    #expect(stack.wireModel == CompositionAcceptance.wireModel)
    #expect(stack.configuredReference == CompositionAcceptance.qualifiedModel)
    #expect(await http.requestedURLs == [Self.responsesURL])
    let headers = await http.lastHeaders
    #expect(headers["Accept"] == "text/event-stream")
    #expect(headers["OpenAI-Beta"] == "responses=experimental")
    #expect(headers["originator"] == "codex_cli_rs")
    #expect(headers["Authorization"] == "Bearer acc-token")
    #expect(headers["session_id"] == "sess-acc")
    let body = try #require(await http.lastBody).utf8String
    #expect(body.contains("\"model\":\"\(CompositionAcceptance.wireModel)\""))
    // the reply reconstructed from item events
    #expect(response.content == "It is noon.")
    #expect(response.usage?.promptTokens == 5)
    #expect(response.usage?.completionTokens == 2)
  }

  /// The load-bearing replay proof: a tool round mints provider state, it is committed to and reloaded
  /// from **real GRDB**, and the terminal round replays it to the same issuer. The replayed reasoning
  /// input item's exact bytes are pinned so any future shape change (e.g. the `summary` field) is a
  /// visible diff, and the two rounds carry two distinct call IDs.
  @Test func multiTurnReplayRoundTripThroughGRDBWithByteGolden() async throws {
    // given — a real session and a RUNNING run
    let stores = try CompositionAcceptance.makeStores()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let chatId: Int64 = 4242
    let claim = try stores.sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: chatId),
        chatId: chatId,
        userId: chatId,
        text: "what time is it?",
        isEdited: false,
        ts: now
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    _ = try stores.runs.pickUp(runId: runId, policyVersion: nil, now: now)

    let firstCallID = ProviderCallID(rawValue: "acc-call-1")
    let secondCallID = ProviderCallID(rawValue: "acc-call-2")

    // given — one composed provider drives both rounds; turn 1 mints replay state
    let http = AcceptanceStreamingHTTP(streamScripts: [
      .init(
        head: CompositionAcceptance.okHead,
        chunks: CompositionAcceptance.toolRound(callID: "call_a", tokens: (7, 3))
      ),
      .init(
        head: CompositionAcceptance.okHead,
        chunks: CompositionAcceptance.terminalRound(tokens: (9, 4))
      ),
    ])
    let stack = try CompositionAcceptance.makeStack(http: http, store: FreshCredentialStore())

    // when — turn 1 (tool round), then commit its assistant anchor + state to GRDB
    let firstReply = try await stack.provider.complete(
      request: ChatRequest(
        model: stack.wireModel,
        messages: [ChatMessage(role: .user, content: "what time is it?")],
        maxOutputTokens: 256
      )
    )
    let mintedState = try #require(firstReply.providerState)
    let commit = try stores.runs.commitAssistantTurn(
      AssistantTurn(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        content: firstReply.content,
        usage: ProviderUsage(
          providerCallID: firstCallID,
          runId: runId,
          sessionId: sessionId,
          model: CompositionAcceptance.qualifiedModel,
          promptTokens: 7,
          completionTokens: 3,
          costUSD: 0,
          costSource: .includedPlan,
          isEstimated: false,
          ts: now
        ),
        chunks: [],
        providerState: mintedState
      ),
      now: now
    )
    #expect(commit == .committed)

    // when — reload the anchor from GRDB and thread it into turn 2
    let reloaded = try stores.sessions.loadContext(
      sessionId: sessionId,
      throughMessageId: .max,
      limit: 50
    )
    let reloadedAssistant = try #require(reloaded.first { $0.role == .assistant })
    let reloadedState = try #require(reloadedAssistant.providerState)
    #expect(reloadedState == mintedState)  // survived the round-trip byte-for-byte

    let secondReply = try await stack.provider.complete(
      request: ChatRequest(
        model: stack.wireModel,
        messages: [
          ChatMessage(role: .user, content: "what time is it?"),
          ChatMessage(
            role: .assistant,
            content: reloadedAssistant.content,
            providerState: reloadedState
          ),
          ChatMessage(role: .user, content: "and the date?"),
        ],
        maxOutputTokens: 256
      )
    )

    // then — turn 2 replayed the reasoning material to the same issuer
    let secondBody = try #require(await http.recorded.last?.body).utf8String
    #expect(secondBody.contains("ENC-A"))
    // byte-golden: the replayed reasoning input item, canonical (sorted-key) form. `summary` is a
    // bare-string array — empty here because this route requests only encrypted content — so this
    // pins the exact wire shape and makes any future change a visible diff.
    #expect(secondBody.contains(#"{"encrypted_content":"ENC-A","summary":[],"type":"reasoning"}"#))
    #expect(secondBody.contains("Let me check."))  // the replayed assistant message text
    #expect(secondReply.content == "It is noon.")

    // then — two distinct call IDs across the rounds
    #expect(firstCallID != secondCallID)
  }

  // MARK: - Doctor (network-free llm.auth row, end to end)

  /// Drives the exact CLI/composition doctor path — `LLMAuthDoctor.inspect` over a real
  /// `EncryptedLLMCredentialStore` folded into a real `DoctorReport` — across three real on-disk
  /// credential states, asserting the rendered `llm.auth` row and the report verdict for each.
  @Test func doctorReportsTheLLMAuthRowForRealCredentialStates() async throws {
    // A usable, fresh credential → an OK oauth row that names the freshness class.
    let fresh = try Self.doctorRow { root in
      _ = try RuntimeSecretPreparer.prepare(
        stateRoot: root,
        environment: [EnvSecretStore.EnvKey.botToken: "tok"]
      )
      try EncryptedLLMCredentialStore(stateRoot: root).save(
        StoredOAuthCredential(
          profileID: UUID(),
          accessToken: "a",
          refreshToken: "r",
          expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        ),
        providerID: .openAIChatGPT
      )
    }
    #expect(fresh.ok)
    #expect(fresh.render.contains("✗ llm.auth") == false)
    #expect(fresh.render.contains("provider=openai-chatgpt mode=oauth status=fresh"))

    // No record on disk → a failing row that guides the owner to log in (live-positive contrast:
    // the fresh case above is the same code path yielding an OK row).
    let missing = try Self.doctorRow { root in
      _ = try RuntimeSecretPreparer.prepare(
        stateRoot: root,
        environment: [EnvSecretStore.EnvKey.botToken: "tok"]
      )
    }
    #expect(missing.ok == false)
    #expect(missing.render.contains("✗ llm.auth"))
    #expect(missing.render.contains("clawd auth login"))

    // A corrupt envelope → a failing decrypt row, not a "just log in" row.
    let corrupt = try Self.doctorRow { root in
      _ = try RuntimeSecretPreparer.prepare(
        stateRoot: root,
        environment: [EnvSecretStore.EnvKey.botToken: "tok"]
      )
      try Data("not an envelope".utf8).write(
        to: SecretStatePaths(stateRoot: root).credentialEnvelope
      )
    }
    #expect(corrupt.ok == false)
    #expect(corrupt.render.contains("credential unreadable"))
  }

  // MARK: - Included-plan accounting

  /// A subscription call resolves to a confirmed zero-dollar `included_plan` cost, and estimated
  /// tokens keep that zero while flipping only the combined estimation flag.
  @Test func includedPlanResolvesConfirmedZeroUSD() {
    // given
    let resolver = CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_002)
    let usage = ChatUsage(promptTokens: 100, completionTokens: 40, totalTokens: 140)

    // when — provider-returned tokens
    let confirmed = resolver.resolve(
      model: CompositionAcceptance.qualifiedModel,
      usage: usage,
      providerCost: nil,
      policy: .includedPlan
    )

    // then
    #expect(confirmed.costUSD == 0)
    #expect(confirmed.source == .includedPlan)
    #expect(confirmed.isEstimated == false)

    // when — the row combines cost source with token estimation; estimated tokens still cost zero
    let estimatedRow = ProviderUsage(
      providerCallID: ProviderCallID(rawValue: "acc-est"),
      runId: nil,
      sessionId: 1,
      model: CompositionAcceptance.qualifiedModel,
      promptTokens: 100,
      completionTokens: 40,
      costUSD: confirmed.costUSD,
      costSource: confirmed.source,
      isEstimated: true,
      ts: Date()
    )

    // then
    #expect(estimatedRow.costUSD == 0)
    #expect(estimatedRow.costSource == .includedPlan)
    #expect(estimatedRow.isEstimated)
  }

  /// Two tool-loop rounds each record usage keyed by a distinct `ProviderCallID`; replaying a commit
  /// with the same ID is idempotent, so run/day totals equal the sum of both rows exactly once.
  @Test func providerCallIDMakesUsageIdempotentAndTotalsSum() async throws {
    // given — a real session and run over real GRDB
    let stores = try CompositionAcceptance.makeStores()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let chatId: Int64 = 77
    let claim = try stores.sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: chatId),
        chatId: chatId,
        userId: chatId,
        text: "hi",
        isEdited: false,
        ts: now
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)

    func usage(_ id: String, prompt: Int, completion: Int) -> ProviderUsage {
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: id),
        runId: runId,
        sessionId: sessionId,
        model: CompositionAcceptance.qualifiedModel,
        promptTokens: prompt,
        completionTokens: completion,
        costUSD: 0,
        costSource: .includedPlan,
        isEstimated: false,
        ts: now
      )
    }

    // when — two distinct rounds, then a replayed terminal commit with the first round's ID
    try stores.usage.recordUsage(usage("round-1", prompt: 7, completion: 3))
    try stores.usage.recordUsage(usage("round-2", prompt: 9, completion: 4))
    try stores.usage.recordUsage(usage("round-1", prompt: 7, completion: 3))  // idempotent replay

    // then — exactly two rows, and the day total is the sum of both, counted once
    let rows = try #require(await readUsageRowCount(stores.writer))
    #expect(rows == 2)
    let totals = try stores.usage.todayTokensAndCost(now: now)
    #expect(totals.tokens == 7 + 3 + 9 + 4)
    #expect(totals.costUSD == 0)
  }

  // MARK: - Helpers

  /// Runs the production doctor `llm.auth` composition — the exact `LLMAuthDoctor.inspect` overload
  /// `DoctorCommand`/`DaemonDoctorReporter` call, over a real encrypted store — against a state root
  /// arranged by `arrange`, and returns the rendered report plus its verdict.
  private static func doctorRow(
    arrange: (URL) throws -> Void
  ) throws -> (render: String, ok: Bool) {
    let root = try makeTemporaryRoot(prefix: "acc-doctor")
    defer { try? FileManager.default.removeItem(at: root) }
    try arrange(root)
    let config = try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
    ])
    let result = LLMAuthDoctor.inspect(
      route: config.llm.route,
      staticAPIKey: nil,
      now: Date(),
      makeManagedStore: { EncryptedLLMCredentialStore(stateRoot: config.stateRoot) }
    )
    var report = DoctorReport()
    report.add(key: "config", value: "OK", group: .config)
    report.add(key: "llm.auth", value: result.value, ok: result.ok, group: .llmRuns)
    return (report.renderText(), report.ok)
  }

  private func readUsageRowCount(_ writer: any DatabaseWriter) throws -> Int {
    try writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage") ?? 0
    }
  }

  private static func makeComposition(
    recorder: CloseOrderRecorder,
    store: any LLMCredentialStore
  ) throws -> RunComposition {
    let config = try CompositionAcceptance.chatGPTConfig()
    var composition = RunComposition(
      config: config,
      secrets: Secrets(telegramBotToken: "token", llmApiKey: nil, searchApiKey: nil),
      stores: try EnvironmentLoader.openStores(config: config),
      logger: Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })
    )
    composition.makeClients = {
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
    composition.makeManagedStore = { _ in store }
    composition.fetchBotUsername = { _ in nil }
    return composition
  }
}

// MARK: - Doubles

private struct StopBuild: Error {}

private actor CloseOrderRecorder {
  private(set) var order: [RuntimeHTTPClientRole] = []

  func record(_ role: RuntimeHTTPClientRole) {
    order.append(role)
  }
}

private final class ComposedStackBox: @unchecked Sendable {
  var value: ProviderStack?
}

private extension Data {
  var utf8String: String { String(bytes: self, encoding: .utf8) ?? "" }
}
