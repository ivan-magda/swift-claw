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
    let recorder = CloseRecorder()
    let store = FreshCredentialStore(present: false)
    let box = StackBox()
    var composition = try Self.makeComposition(recorder: recorder, store: store)
    composition.buildDaemon = { _, stack in
      box.stack = stack
      throw StopBuild()
    }

    // when / then — the build stopped after the stack was resolved, and every client closed
    await #expect(throws: StopBuild.self) {
      _ = try await composition.compose()
    }
    #expect(store.loadCount == 1)
    #expect(box.stack?.costPolicy == .includedPlan)
    #expect(box.stack?.reservationPolicy == .chatGPTReplayState)
    #expect(box.stack?.configuredReference == CompositionAcceptance.qualifiedModel)
    #expect(box.stack?.wireModel == CompositionAcceptance.wireModel)
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
  /// visible diff, and the final assistant reply carries the same derived replay identity.
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

    // A fixed key for turn 1's usage row: this test keys accounting rows, it does not exercise the
    // live per-round ID generator. That the generator mints distinct, lowercase, non-empty IDs is
    // proven by `LLMAccountingTests.theLiveGeneratorMintsDistinctLowercaseIdentifiers`.
    let firstCallID = ProviderCallID(rawValue: "acc-call-1")

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

    // then — the final assistant reply is stamped too, with the identity this history derived: no
    // recovery here, so its issuer is the reloaded state's epoch, not a fresh one.
    #expect(secondReply.providerState?.issuer == reloadedState.issuer)
  }

  // MARK: - Invalid-state epoch recovery surviving restart

  /// The Task-20 recovery, proven to survive a restart. A turn whose replayed state the backend
  /// rejects as `invalid_encrypted_content` recovers state-free into a NEW epoch and stamps the reply
  /// with it (even the empty payload of a reasoning-free terminal round); that epoch is committed to
  /// **real GRDB**. A simulated restart — a fresh composed provider/codec reloading the same history —
  /// derives the new epoch from the newest compatible state and never replays the older poisoned
  /// material again. Without the empty stamp surviving, the newest compatible state on reload would be
  /// the poisoned one and the recovery would be undone; this pins that it is not.
  @Test func invalidStateEpochRecoverySurvivesRestart() async throws {
    // given — a real session and a RUNNING run
    let stores = try CompositionAcceptance.makeStores()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let chatId: Int64 = 5150
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
    let firstRunId = try #require(claim.runId)
    _ = try stores.runs.pickUp(runId: firstRunId, policyVersion: nil, now: now)

    // given — turn 1 mints replay state carrying the reasoning ENC-A under an initial epoch; turn 2
    // then replays it, the backend rejects it as poisoned, and the state-free recovery succeeds.
    let firstHTTP = AcceptanceStreamingHTTP(streamScripts: [
      .init(
        head: CompositionAcceptance.okHead,
        chunks: CompositionAcceptance.toolRound(callID: "call_a", tokens: (7, 3))
      ),
      .init(
        head: CompositionAcceptance.invalidEncryptedContentHead,
        chunks: CompositionAcceptance.invalidEncryptedContentBody()
      ),
      .init(
        head: CompositionAcceptance.okHead,
        chunks: CompositionAcceptance.terminalRound(tokens: (9, 4))
      ),
    ])
    let firstStack = try CompositionAcceptance.makeStack(
      http: firstHTTP,
      store: FreshCredentialStore()
    )

    // when — turn 1, then commit its assistant anchor + poisoned-epoch state
    let firstReply = try await firstStack.provider.complete(
      request: ChatRequest(
        model: firstStack.wireModel,
        messages: [ChatMessage(role: .user, content: "what time is it?")],
        maxOutputTokens: 256
      )
    )
    let poisonedState = try #require(firstReply.providerState)
    let firstCommit = try commitAssistantAnchor(
      stores,
      runId: firstRunId,
      sessionId: sessionId,
      chatId: chatId,
      content: firstReply.content,
      state: poisonedState,
      callID: "epoch-r1",
      now: now
    )
    #expect(firstCommit == .committed)

    // when — turn 2 replays the poisoned anchor; the backend rejects it and the provider recovers
    let poisonedAnchor = try #require(
      try stores.sessions
        .loadContext(sessionId: sessionId, throughMessageId: .max, limit: 50)
        .first { $0.role == .assistant }
    )
    let poisonedAnchorState = try #require(poisonedAnchor.providerState)
    let recoveredReply = try await firstStack.provider.complete(
      request: ChatRequest(
        model: firstStack.wireModel,
        messages: [
          ChatMessage(role: .user, content: "what time is it?"),
          ChatMessage(
            role: .assistant,
            content: poisonedAnchor.content,
            providerState: poisonedAnchorState
          ),
          ChatMessage(role: .user, content: "and the date?"),
        ],
        maxOutputTokens: 256
      )
    )

    // then — recovery ran (reject then state-free retry), stamped a NEW epoch, and did not resend
    // the poisoned reasoning on the retry
    let recoveredState = try #require(recoveredReply.providerState)
    #expect(recoveredState.issuer != poisonedState.issuer)
    #expect(await firstHTTP.recorded.count == 3)
    let retryBody = try #require(await firstHTTP.recorded.last?.body).utf8String
    #expect(retryBody.contains("ENC-A") == false)

    // the recovered epoch is the record a restart must derive from, even with an empty payload —
    // committed on its own run, as each turn is in production
    let secondClaim = try stores.sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 2,
        sessionKey: SessionKey.telegramDM(chatId: chatId),
        chatId: chatId,
        userId: chatId,
        text: "and the date?",
        isEdited: false,
        ts: now
      )
    )
    let secondRunId = try #require(secondClaim.runId)
    _ = try stores.runs.pickUp(runId: secondRunId, policyVersion: nil, now: now)
    let recoveredCommit = try commitAssistantAnchor(
      stores,
      runId: secondRunId,
      sessionId: sessionId,
      chatId: chatId,
      content: recoveredReply.content,
      state: recoveredState,
      callID: "epoch-r2",
      now: now
    )
    #expect(recoveredCommit == .committed)

    // when — RESTART: a fresh composed provider/codec over the same GRDB history threads the whole
    // conversation — both the poisoned anchor and the recovered one — into the next turn
    let restartHTTP = AcceptanceStreamingHTTP(streamScripts: [
      .init(
        head: CompositionAcceptance.okHead,
        chunks: CompositionAcceptance.terminalRound(tokens: (2, 1))
      )
    ])
    let restartStack = try CompositionAcceptance.makeStack(
      http: restartHTTP,
      store: FreshCredentialStore()
    )
    let anchors = try stores.sessions
      .loadContext(sessionId: sessionId, throughMessageId: .max, limit: 50)
      .filter { $0.role == .assistant }
    #expect(anchors.count == 2)  // both epochs are on disk

    let threaded =
      [ChatMessage(role: .user, content: "what time is it?")]
      + anchors.map { anchor in
        ChatMessage(role: .assistant, content: anchor.content, providerState: anchor.providerState)
      }
      + [ChatMessage(role: .user, content: "still there?")]
    _ = try await restartStack.provider.complete(
      request: ChatRequest(
        model: restartStack.wireModel,
        messages: threaded,
        maxOutputTokens: 256
      )
    )

    // then — the restart derived the recovered epoch from the newest compatible state and never
    // reintroduced the older poisoned material
    let restartBody = try #require(await restartHTTP.recorded.last?.body).utf8String
    #expect(restartBody.contains("ENC-A") == false)
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

  /// A subscription call resolves to a confirmed zero-dollar `included_plan` cost through the real
  /// resolver. That an estimated-token row keeps that zero while flipping only the estimation flag is
  /// covered by `LLMAccountingTests.missingCountsRecordAnEstimatedIncludedPlanRowWhoseZeroStaysConfirmed`;
  /// asserting fields of a locally-built `ProviderUsage` here would prove only the initializer.
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
    let rows = try readUsageRowCount(stores.writer)
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

  /// Commits one assistant anchor carrying `state` and a zero-cost included-plan usage row keyed by
  /// `callID` — the real GRDB round-trip an epoch must survive.
  private func commitAssistantAnchor(
    _ stores: (
      writer: any DatabaseWriter,
      sessions: SessionMessageStoreGRDB,
      runs: RunStoreGRDB,
      usage: UsageStoreGRDB
    ),
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    content: String,
    state: ProviderExchangeState,
    callID: String,
    now: Date
  ) throws -> RunCommitResult {
    try stores.runs.commitAssistantTurn(
      AssistantTurn(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        content: content,
        usage: ProviderUsage(
          providerCallID: ProviderCallID(rawValue: callID),
          runId: runId,
          sessionId: sessionId,
          model: CompositionAcceptance.qualifiedModel,
          promptTokens: 0,
          completionTokens: 0,
          costUSD: 0,
          costSource: .includedPlan,
          isEstimated: false,
          ts: now
        ),
        chunks: [],
        providerState: state
      ),
      now: now
    )
  }

  private func readUsageRowCount(_ writer: any DatabaseWriter) throws -> Int {
    try writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage") ?? 0
    }
  }

  private static func makeComposition(
    recorder: CloseRecorder,
    store: any LLMCredentialStore
  ) throws -> RunComposition {
    let config = try CompositionAcceptance.chatGPTConfig()
    var composition = RunComposition(
      config: config,
      secrets: Secrets(telegramBotToken: "token", llmApiKey: nil, searchApiKey: nil),
      stores: try EnvironmentLoader.openStores(config: config),
      logger: Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })
    )
    composition.makeClients = { instrumentedClients(recorder: recorder) }
    composition.makeManagedStore = { _ in store }
    composition.fetchBotUsername = { _, _ in nil }
    return composition
  }
}

// MARK: - Doubles

private struct StopBuild: Error {}

private extension Data {
  var utf8String: String { String(bytes: self, encoding: .utf8) ?? "" }
}
