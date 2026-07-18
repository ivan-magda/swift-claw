import ClawAuth
import ClawCore
import Foundation
import Logging

/// The subscription ChatGPT provider: one endpoint, one header set, and one attempt engine that both
/// `complete` and `stream` drive.
///
/// The endpoint is a compile-time constant so no configured base URL can ever receive a subscription
/// bearer, and the bearer headers are built only after that fixed URL has been chosen. The credential
/// source is allowlisted to exactly two headers — `Authorization` and the optional
/// `ChatGPT-Account-ID` — so nothing it hands back through the header dictionary can replace a header
/// this adapter owns. `complete` and `stream` differ only in where visible deltas go: they build the
/// same plan and run the same engine, so their terminal reply, usage, tool calls, replay state, and
/// retry count are identical on the same wire.
public struct ChatGPTResponsesProvider<ClockType: Clock>: LLMProvider, Sendable
where ClockType.Duration == Duration {
  private let engine: ChatGPTResponsesAttemptEngine
  private let codec: ChatGPTProviderStateCodec
  private let encoder = ChatGPTResponsesRequestEncoder()
  private let credentialProfileID: UUID?
  private let userAgent: String
  private let requestTimeoutSeconds: Int

  /// - Parameter credentialProfileID: the stable local profile identity replay state is bound to. An
  ///   absent ID is valid only for the logged-out provider, whose credential source fails
  ///   authentication before any inference; a live provider always carries one.
  /// - Parameter buildVersion: `ClawdVersion.current`, sanitized here into the User-Agent so a
  ///   version carrying stray bytes cannot fold a header of its own.
  /// - Parameter epochID: mints replay epochs; injected so a test can name the epoch a history
  ///   derives instead of matching against randomness.
  public init(
    http: any HTTPStreaming,
    credentials: any LLMCredentialSource,
    credentialProfileID: UUID?,
    buildVersion: String,
    retryBudget: Int,
    requestTimeoutSeconds: Int,
    clock: ClockType,
    jitter: @escaping @Sendable (Duration) -> Duration,
    epochID: @escaping @Sendable () -> UUID
  ) {
    self.init(
      http: http,
      credentials: credentials,
      credentialProfileID: credentialProfileID,
      buildVersion: buildVersion,
      retryBudget: retryBudget,
      requestTimeoutSeconds: requestTimeoutSeconds,
      clock: clock,
      jitter: jitter,
      epochID: epochID,
      // The bootstrapped default handler, never a forced no-op: this is the only path production wires
      // from `clawd`, so silencing it here would sink the replay-drop diagnostic and every engine line
      // with it. A nil reporter below then routes drops through this same logger, counts only.
      logger: Logger(label: "clawd.llm"),
      replayDropsReporter: nil
    )
  }

  /// The designated init, internal so a test can observe the replay-drops diagnostic and silence or
  /// capture logs without widening the public surface past the pinned signature above.
  init(
    http: any HTTPStreaming,
    credentials: any LLMCredentialSource,
    credentialProfileID: UUID?,
    buildVersion: String,
    retryBudget: Int,
    requestTimeoutSeconds: Int,
    clock: ClockType,
    jitter: @escaping @Sendable (Duration) -> Duration,
    epochID: @escaping @Sendable () -> UUID,
    logger: Logger,
    replayDropsReporter: (@Sendable (ChatGPTReplayDrops) -> Void)?
  ) {
    self.credentialProfileID = credentialProfileID
    self.requestTimeoutSeconds = requestTimeoutSeconds
    self.userAgent = Self.userAgent(buildVersion: buildVersion)

    // Never left as the codec's silent no-op: a dropped foreign or malformed state emits a
    // counts-only diagnostic. `ChatGPTReplayDrops` is all integers by construction, so a reporter is
    // handed no payload or issuer even if one tried to spill it.
    let reporter: @Sendable (ChatGPTReplayDrops) -> Void =
      replayDropsReporter
      ?? { drops in
        logger.notice(
          """
          chatgpt replay state dropped \
          foreign=\(drops.foreign) staleEpoch=\(drops.staleEpoch) malformed=\(drops.malformed) \
          oversized=\(drops.oversized) budgetEvicted=\(drops.budgetEvicted)
          """
        )
      }
    self.codec = ChatGPTProviderStateCodec(newEpoch: epochID, reportDrops: reporter)

    self.engine = ChatGPTResponsesAttemptEngine(
      credentials: credentials,
      http: http,
      clock: clock,
      jitter: jitter,
      retryBudget: retryBudget,
      requestTimeoutSeconds: requestTimeoutSeconds,
      logger: logger
    )
  }

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    switch makePlan(for: request) {
    case .failure(let cause):
      // Nothing reached the wire, so the accounting is `notStarted` — carried on the failure rather
      // than dropped, so the runtime does not estimate-debit a call that never left.
      throw ProviderFailure(cause: cause, accounting: .notStarted)
    case .success(let plan):
      switch await engine.run(plan: plan, emitDelta: Self.discardDelta) {
      case .completed(let response):
        return response
      case .failed(let failure):
        // The whole failure travels, cause and accounting together: a budget-exhausted clean 5xx
        // reports `notStarted`, and throwing the bare cause would strand that fact and invite a
        // false debit.
        throw failure
      case .cancelled(let accounting):
        throw Self.cancellation(for: accounting)
      }
    }
  }

  public func stream(request: ChatRequest) -> LLMEventStream {
    let planResult = makePlan(for: request)
    let engine = engine
    return LLMEventStream.make { sink in
      switch planResult {
      case .failure(let cause):
        return .failed(ProviderFailure(cause: cause, accounting: .notStarted))
      case .success(let plan):
        return await engine.run(plan: plan) { text in
          try await sink.sendDelta(text)
        }
      }
    }
  }
}

// MARK: - Plan Assembly

private extension ChatGPTResponsesProvider {
  /// The all-zero profile a logged-out provider decodes history against. Its identity is never sent:
  /// the credential source fails authentication before any request is encoded, so this only keeps the
  /// pure plan build total.
  static var loggedOutProfileID: UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  }

  /// The delta sink `complete` runs the engine with — it consumes the same SSE as `stream` and simply
  /// drops the visible deltas rather than publishing them.
  @Sendable static func discardDelta(_ text: String) async throws {}

  /// Validates the route-incompatible fields, then builds the replay selection, identity, and the
  /// per-attempt encoder — everything an attempt needs except the credential, which the engine
  /// resolves per wire attempt. A refusal here is a `Result` rather than a throw so both entry points
  /// can report it their own way without duplicating the assembly.
  func makePlan(for request: ChatRequest) -> Result<ChatGPTResponsesAttemptPlan, ProviderError> {
    // A stop string this route cannot honor, or a structured-output shape it does not accept, fails
    // before any network I/O rather than changing what the model was asked for.
    guard request.stop == nil else {
      return .failure(
        .terminal(status: nil, message: "the ChatGPT route has no stop-string contract to honor")
      )
    }
    guard request.responseFormat == nil else {
      return .failure(
        .terminal(status: nil, message: "the ChatGPT route requires structured output to be off")
      )
    }

    let wireModel = ChatGPTResponsesRequestEncoder.wireModel(for: request.model)
    let profileID = credentialProfileID ?? Self.loggedOutProfileID
    let selection = codec.decodeCompatibleHistory(
      messages: request.messages,
      profileID: profileID,
      wireModel: wireModel
    )

    let encoder = encoder
    let userAgent = userAgent
    let timeoutSeconds = requestTimeoutSeconds
    let plan = ChatGPTResponsesAttemptPlan(
      codec: codec,
      identity: selection.identity,
      profileID: profileID,
      wireModel: wireModel,
      encodeRequest: { authorization, includePriorState, beginHandoff in
        let headers = try Self.headers(
          for: authorization,
          userAgent: userAgent,
          sessionID: request.sessionId
        )
        let body = try encoder.encode(
          request: request,
          replaying: selection,
          includePriorState: includePriorState
        )
        // The endpoint is the fixed constant, chosen before the bearer headers above were built, and
        // the streaming policy is forced on both entry points so `complete` reads the same SSE.
        return HTTPRequest(
          method: .post,
          url: ChatGPTProviderMetadata.responsesURL,
          headers: headers,
          body: body,
          timeout: .seconds(timeoutSeconds),
          responseBodyPolicy: .streaming(
            maximumUnreadBytes: HTTPResponseBodyPolicy.maximumUnreadStreamBytes,
            errorBytes: HTTPResponseBodyPolicy.diagnosticBodyBytes
          ),
          beginHandoff: beginHandoff
        )
      }
    )
    return .success(plan)
  }

  static func cancellation(for accounting: ProviderFailureAccounting) -> any Error {
    switch accounting {
    case .notStarted:
      // The caller changed its mind before anything was asked; a raw cancellation is the whole story.
      return CancellationError()
    case .mayHaveStarted(let observed):
      // The model may have been asked, so the tokens it may have generated still have to be
      // accounted for — `complete` has no session to report that through, so it rides the error.
      return ProviderInferenceCancellation(observing: observed)
    }
  }
}

// MARK: - Headers

private extension ChatGPTResponsesProvider {
  static var maximumBuildVersionBytes: Int { 256 }

  /// The two headers a credential source may contribute, keyed by normalized name and mapped to the
  /// single spelling that reaches the wire. Everything else about how the request is framed —
  /// content negotiation, the beta flag, the impersonated client identity, session routing — is this
  /// adapter's alone.
  static var allowedCredentialHeaders: [String: String] {
    [
      "authorization": "Authorization",
      "chatgpt-account-id": ChatGPTProviderMetadata.accountHeaderName,
    ]
  }

  static func userAgent(buildVersion: String) -> String {
    // Sanitized as a header value: control-free and single-line, so a version string carrying a
    // newline or an escape cannot inject a header of its own.
    let safe = ChatGPTWireValues.safeRemoteDiagnostic(
      buildVersion,
      redacting: [],
      maxBytes: maximumBuildVersionBytes
    )
    return "codex_cli_rs/0.0.0 (swift-claw/\(safe))"
  }

  /// Folds the credential source's contribution into this adapter's own headers under the allowlist.
  ///
  /// The seam is a plain dictionary, so without the allowlist any source could rewrite `Host`,
  /// content negotiation, the beta flag, or session routing on the way to the wire. A name outside
  /// the allowlist, or one this adapter already owns, is refused rather than merged — and the refusal
  /// quotes only the name, never the value it came with.
  static func headers(
    for authorization: LLMRequestAuthorization,
    userAgent: String,
    sessionID: String?
  ) throws -> [String: String] {
    var adapterHeaders: [String: String] = [
      "Content-Type": "application/json",
      "Accept": "text/event-stream",
      "OpenAI-Beta": "responses=experimental",
      "originator": "codex_cli_rs",
      "User-Agent": userAgent,
    ]
    if let sessionID {
      adapterHeaders["session_id"] = sessionID
      adapterHeaders["x-client-request-id"] = sessionID
    }
    return try CredentialHeaderMerge.merged(
      into: adapterHeaders,
      allowing: allowedCredentialHeaders,
      from: authorization
    )
  }
}
