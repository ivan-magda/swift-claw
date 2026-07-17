import ClawAuth
import ClawCore
import Foundation
import Logging

// MARK: - Plan

/// The per-call material the provider hands the shared engine. The provider owns the endpoint,
/// headers, and request encoding this carries; the engine owns the retry budget, the exposure
/// reducer, credential rejection, and the state-free recovery. Splitting it this way is what lets one
/// engine drive both `complete` and `stream` without either learning the other's request shape.
struct ChatGPTResponsesAttemptPlan: Sendable {
  /// Assembles the reply and mints the recovery epoch. The engine holds it so a state-free recovery
  /// and the response stamping speak of the same identity space.
  let codec: ChatGPTProviderStateCodec

  /// The identity a normal attempt stamps its success with — the one the history derived.
  let identity: ChatGPTReplayIdentity

  /// The origin a recovery epoch is minted for. These are the request's own profile and wire model,
  /// so the recovery identity lands on the same origin as the normal one, differing only in epoch.
  let profileID: UUID
  let wireModel: String

  /// Encodes one wire request. `includePriorState` is false only on the single state-free recovery
  /// attempt, where the poisoned replay state must be dropped. The engine supplies the handoff that
  /// linearizes the attempt's exposure and calls this once per wire attempt.
  let encodeRequest:
    @Sendable (
      _ authorization: LLMRequestAuthorization,
      _ includePriorState: Bool,
      _ beginHandoff: @escaping @Sendable () throws -> Void
    ) throws -> HTTPRequest
}

// MARK: - Engine

/// The one component both Responses entry points drive: it owns the exposure reducer per attempt and
/// the single wire-attempt budget shared across every retry class.
///
/// Two facts hold the no-double-billing guarantee together. A recognized non-success head proves the
/// server answered instead of inferring, so exposure resets to `notStarted` and a clean retryable
/// class may be replayed. And the retry boundary closes on the first non-comment SSE `data:` byte:
/// after it, an ambiguous sent attempt must never be replayed, so a disconnect, malformed frame, or
/// in-band error degrades conservatively instead. One budget counts every wire attempt — clean-401
/// refresh, replay-state recovery, 408, 429, 5xx, and definitely-not-sent transport retries — so no
/// path silently resets it.
struct ChatGPTResponsesAttemptEngine: Sendable {
  private let credentials: any LLMCredentialSource
  private let http: any HTTPStreaming
  private let backoff: RetryBackoff
  private let retryBudget: Int
  private let logger: Logger

  init(
    credentials: any LLMCredentialSource,
    http: any HTTPStreaming,
    clock: any Clock<Duration>,
    jitter: @escaping @Sendable (Duration) -> Duration,
    retryBudget: Int,
    requestTimeoutSeconds: Int,
    logger: Logger = Logger(label: "clawd.llm", factory: { _ in SwiftLogNoOpLogHandler() })
  ) {
    self.credentials = credentials
    self.http = http
    self.backoff = RetryBackoff(
      clock: clock,
      jitter: jitter,
      requestTimeoutSeconds: requestTimeoutSeconds
    )
    self.retryBudget = retryBudget
    self.logger = logger
  }

  /// Runs the whole call — authorize, dispatch, classify, and retry within the budget — reporting how
  /// it ended rather than throwing, so a stream session can cache the value and `complete` can map
  /// its two cancellation states to raw or typed errors. `emitDelta` receives each owner-visible text
  /// delta; `complete` passes a sink that discards them.
  func run(
    plan: ChatGPTResponsesAttemptPlan,
    emitDelta: @escaping @Sendable (String) async throws -> Void
  ) async -> LLMStreamTermination {
    if Task.isCancelled {
      return .cancelled(.notStarted)
    }

    var state = CallState(replayMode: .normal(plan.identity))
    while true {
      switch await runAttempt(plan: plan, state: &state, emitDelta: emitDelta) {
      case .stop(let termination):
        return termination
      case .retryImmediately:
        continue
      case .retryAfter(let delay):
        do {
          try await backoff.wait(retryAfter: delay, attempt: state.attempt)
        } catch {
          // Retries only ever follow a clean reset, so a cancelled backoff owes no usage.
          return .cancelled(.notStarted)
        }
      }
    }
  }
}

// MARK: - Attempt loop

private extension ChatGPTResponsesAttemptEngine {
  /// The transient cause a first 401 surfaces when its refresh cannot be retried this turn. The
  /// credential is intact and now marked for refresh, so the next turn heals on its own — this reads
  /// as "try again", never as "log in again".
  static let credentialRefreshing = ProviderError.retryable(
    status: nil,
    message: "the ChatGPT credential is being refreshed"
  )

  /// What one wire attempt asks the loop to do next.
  enum LoopControl {
    case stop(LLMStreamTermination)
    case retryImmediately
    case retryAfter(Duration?)
  }

  /// The retry state that survives across a call's attempts. Bundled so the per-attempt helpers pass
  /// one value rather than four, and so the shared budget reads from one counter.
  struct CallState {
    var attempt = 0
    var refreshRequested = false
    var recoveryUsed = false
    var replayMode: ReplayMode
  }

  /// Runs one wire attempt: check cancellation, authorize, encode, dispatch, and classify. The budget
  /// gate lives here so clean-401 refresh, state-free recovery, throttle, and transient backoff all
  /// consult the one `attempt < retryBudget` test — no class can spend an attempt another already did.
  func runAttempt(
    plan: ChatGPTResponsesAttemptPlan,
    state: inout CallState,
    emitDelta: @escaping @Sendable (String) async throws -> Void
  ) async -> LoopControl {
    state.attempt += 1
    if Task.isCancelled {
      return .stop(.cancelled(.notStarted))
    }

    let exposure = ProviderAttemptExposure()
    let authorization: LLMRequestAuthorization
    do {
      authorization = try await credentials.authorization()
    } catch is CancellationError {
      return .stop(.cancelled(.notStarted))
    } catch let credentialError as ChatGPTCredentialError {
      // No request goes out without a credential, so nothing was exposed. A throttle or a transient
      // token-endpoint fault must not be reported as "log in again": it heals on its own, so it maps
      // to a quota/transient cause. Only a genuinely dead credential keeps authenticationRequired.
      return .stop(
        .failed(ProviderFailure(cause: Self.cause(for: credentialError), accounting: .notStarted))
      )
    } catch {
      // An unrecognized authorization failure names the state rather than the source's error,
      // keeping any key material out of the terminal, and stays conservative: a login repairs it.
      return .stop(
        .failed(ProviderFailure(cause: .authenticationRequired, accounting: .notStarted))
      )
    }

    let context = ResponseContext(
      codec: plan.codec,
      identity: state.replayMode.identity,
      redactionValues: authorization.redactionValues
    )
    let request: HTTPRequest
    do {
      request = try plan.encodeRequest(authorization, state.replayMode.includesPriorState) {
        try exposure.beginHandoff()
      }
    } catch {
      // Encoding failed before the handoff, so nothing reached the wire.
      return .stop(.failed(exposure.failure(context.redactedCause(for: error))))
    }

    let canRetry = state.attempt < retryBudget
    switch await dispatch(request, exposure: exposure, context: context, emitDelta: emitDelta) {
    case .terminal(let termination):
      return .stop(termination)
    case .transportRetryable(let cause):
      guard canRetry else {
        return .stop(.failed(exposure.failure(cause)))
      }
      logger.notice("chatgpt responses transport retry (attempt \(state.attempt)/\(retryBudget))")
      return .retryAfter(nil)
    case .head(let diagnosis):
      return await applyHead(
        diagnosis,
        authorization: authorization,
        exposure: exposure,
        state: &state,
        plan: plan
      )
    }
  }

  /// Applies a classified non-success head: the async credential rejection and the state transition
  /// live here, off the dispatch path, so the pure classifier stays free of side effects. The budget
  /// gate is recomputed from the same counter `runAttempt` reads, so the two never diverge.
  func applyHead(
    _ diagnosis: HeadDiagnosis,
    authorization: LLMRequestAuthorization,
    exposure: ProviderAttemptExposure,
    state: inout CallState,
    plan: ChatGPTResponsesAttemptPlan
  ) async -> LoopControl {
    switch decide(
      diagnosis,
      canRetry: state.attempt < retryBudget,
      refreshRequested: state.refreshRequested,
      recoveryUsed: state.recoveryUsed
    ) {
    case .fail(let cause):
      return .stop(.failed(exposure.failure(cause)))

    case .refreshThenRetry:
      await credentials.reject(generation: authorization.generation, disposition: .refresh)
      state.refreshRequested = true
      return .retryImmediately

    case .refreshWithoutRetry:
      // The budget is spent, but a first 401 still refreshes: mark the credential for refresh so the
      // next turn carries the fresh token, and surface a transient failure rather than a login prompt.
      await credentials.reject(generation: authorization.generation, disposition: .refresh)
      state.refreshRequested = true
      return .stop(.failed(exposure.failure(Self.credentialRefreshing)))

    case .latchAuthenticationRequired:
      await credentials.reject(
        generation: authorization.generation,
        disposition: .authenticationRequired
      )
      return .stop(.failed(exposure.failure(.authenticationRequired)))

    case .recoverStateFree:
      state.replayMode = .stateFree(
        plan.codec.stateFreeRecoveryIdentity(profileID: plan.profileID, wireModel: plan.wireModel)
      )
      state.recoveryUsed = true
      return .retryImmediately

    case .backoffThenRetry(let delay):
      return .retryAfter(delay)
    }
  }
}

// MARK: - Credential failure mapping

private extension ChatGPTResponsesAttemptEngine {
  /// The vendor-neutral cause a credential failure surfaces. The source distinguishes a dead
  /// credential from a throttle or a brief token-endpoint outage; that distinction has to survive to
  /// the owner, or a healthy credential in cooldown gets a re-login prompt for a condition that heals
  /// itself. Every `ChatGPTCredentialError` is documented owner-safe, so mapping its identity leaks
  /// nothing — and only `.authenticationRequired` earns the terminal login prompt.
  static func cause(for credentialError: ChatGPTCredentialError) -> ProviderError {
    switch credentialError {
    case .authenticationRequired:
      return .authenticationRequired
    case .throttled(let retryAfter):
      return .quotaLimited(retryAfterSeconds: Self.wholeSeconds(retryAfter))
    case .temporarilyUnavailable, .persistenceFailed, .shuttingDown:
      // The credential is intact; the token endpoint is briefly unhealthy or the daemon is stopping.
      // A retry heals it, so this is a transient outage rather than a login failure.
      return .retryable(status: nil, message: "the ChatGPT credential was temporarily unavailable")
    }
  }

  /// A bounded wait rounded up to whole seconds, so a sub-second cooldown still reads as "try again
  /// in 1 second" rather than "0 seconds".
  static func wholeSeconds(_ duration: Duration) -> Int {
    let components = duration.components
    let seconds = Int(components.seconds)
    return components.attoseconds > 0 ? seconds + 1 : seconds
  }
}

// MARK: - Response context

private extension ChatGPTResponsesAttemptEngine {
  /// Everything one attempt's reply is read against: the codec and identity it is stamped with, and
  /// the redactor built from the credential the attempt carried. Bundled so the reply-reading path
  /// takes one value, and so redaction always uses the authorization actually in force.
  struct ResponseContext {
    let codec: ChatGPTProviderStateCodec
    let identity: ChatGPTReplayIdentity
    let redactionValues: [String]
    let redactor: SecretRedactor

    init(
      codec: ChatGPTProviderStateCodec,
      identity: ChatGPTReplayIdentity,
      redactionValues: [String]
    ) {
      self.codec = codec
      self.identity = identity
      self.redactionValues = redactionValues
      self.redactor = SecretRedactor(secretValues: redactionValues)
    }

    /// A natural error's provider cause, redacted. A transport failure already carries a sanitized
    /// message; a `ProviderError` from the parser or accumulator passes through; anything else is a
    /// transient with its description.
    func redactedCause(for error: any Error) -> ProviderError {
      if let transport = error as? HTTPTransportFailure {
        return .retryable(status: nil, message: redactor.redact(transport.safeMessage))
      }
      if let providerError = error as? ProviderError {
        return providerError.redacted(with: redactor)
      }
      return .retryable(status: nil, message: redactor.redact("\(error)"))
    }
  }

  /// Which replay identity the current attempt carries, and whether it still sends prior state. Once
  /// a state-free recovery is entered it stays entered: the poisoned state is not re-added on a later
  /// retry within the same call.
  enum ReplayMode {
    case normal(ChatGPTReplayIdentity)
    case stateFree(ChatGPTReplayIdentity)

    var identity: ChatGPTReplayIdentity {
      switch self {
      case .normal(let identity), .stateFree(let identity):
        return identity
      }
    }

    var includesPriorState: Bool {
      switch self {
      case .normal:
        return true
      case .stateFree:
        return false
      }
    }
  }
}

// MARK: - Dispatch

private extension ChatGPTResponsesAttemptEngine {
  /// What one dispatched attempt resolved to: a terminal outcome to return, a clean transport failure
  /// eligible for a shared retry, or a non-success head for the classifier to judge.
  enum Dispatch {
    case terminal(LLMStreamTermination)
    case transportRetryable(ProviderError)
    case head(HeadDiagnosis)
  }

  /// Opens the stream and, for a 2xx head, consumes it to a terminal outcome that is never retried. A
  /// recognized non-success head resets exposure to `notStarted` before its diagnostic body is even
  /// read, so a later refresh, sleep, or retry acts on a clean attempt.
  func dispatch(
    _ request: HTTPRequest,
    exposure: ProviderAttemptExposure,
    context: ResponseContext,
    emitDelta: @escaping @Sendable (String) async throws -> Void
  ) async -> Dispatch {
    let exchange: HTTPStreamExchange
    do {
      exchange = try await http.openStream(request)
    } catch is CancellationError {
      // The handoff refused, or the transport unwound: the reducer owns whether the model was asked.
      return .terminal(.cancelled(exposure.accounting))
    } catch let transport as HTTPTransportFailure {
      return transportDispatch(transport, exposure: exposure, redactor: context.redactor)
    } catch {
      return .terminal(.failed(exposure.failure(context.redactedCause(for: error))))
    }

    guard (200..<300).contains(exchange.head.statusCode) else {
      // The server answered instead of inferring, so this attempt generated nothing.
      exposure.noteProvenClean()
      let diagnosis = await diagnose(exchange, redactionValues: context.redactionValues)
      return .head(diagnosis)
    }

    return .terminal(
      await consume(exchange, exposure: exposure, context: context, emitDelta: emitDelta)
    )
  }

  /// A transport failure maps by its typed disposition, never by its text. `definitelyNotSent` proves
  /// nothing reached the model, so exposure resets and the attempt is replayable; anything else may
  /// have been sent and is conservative and terminal.
  func transportDispatch(
    _ transport: HTTPTransportFailure,
    exposure: ProviderAttemptExposure,
    redactor: SecretRedactor
  ) -> Dispatch {
    let message = redactor.redact(transport.safeMessage)
    switch transport.disposition {
    case .definitelyNotSent:
      exposure.noteProvenClean()
      return .transportRetryable(.retryable(status: nil, message: message))
    case .mayHaveBeenSent:
      return .terminal(.failed(exposure.failure(.retryable(status: nil, message: message))))
    }
  }
}

// MARK: - Stream consumption

private extension ChatGPTResponsesAttemptEngine {
  /// Reads a 2xx stream, emitting owner-visible deltas and joining the exchange on every exit. Once a
  /// terminal is decided the exchange is cancelled and joined promptly rather than waiting for the
  /// server's EOF. Nothing here is ever retried: a 2xx head has already moved exposure past the point
  /// a replay would be safe, and the first data byte has closed the retry boundary.
  func consume(
    _ exchange: HTTPStreamExchange,
    exposure: ProviderAttemptExposure,
    context: ResponseContext,
    emitDelta: @escaping @Sendable (String) async throws -> Void
  ) async -> LLMStreamTermination {
    var parser = ChatGPTResponsesSSEParser()
    var accumulator = ChatGPTResponsesAccumulator(
      codec: context.codec,
      identity: context.identity,
      redactionValues: context.redactionValues
    )
    var terminal: ChatResponse?

    do {
      for try await chunk in exchange.body {
        for streamEvent in try accumulator.consume(try parser.push(chunk)) {
          switch streamEvent {
          case .delta(let text):
            try await emitDelta(text)
          case .finished(let response):
            terminal = response
          }
        }
        exposure.noteObserved(completionTokens: accumulator.observedCompletionTokens)
        if terminal != nil {
          break
        }
      }

      if let terminal {
        _ = await exchange.cancelAndAwait()
        return .completed(terminal)
      }

      // The body ended without an in-band terminal. Confirm the transfer actually finished before
      // asking the accumulator, so a truncated transfer surfaces as its transport cause rather than
      // as an ambiguous end.
      if let transferError = Self.transferError(await exchange.awaitTermination()) {
        throw transferError
      }
      _ = try accumulator.finish()
      return .failed(exposure.failure(.terminal(status: nil, message: "the ChatGPT reply ended")))
    } catch is CancellationError {
      _ = await exchange.cancelAndAwait()
      return .cancelled(exposure.accounting)
    } catch {
      _ = await exchange.cancelAndAwait()
      return .failed(exposure.failure(context.redactedCause(for: error)))
    }
  }

  static func transferError(_ termination: HTTPStreamTermination) -> (any Error)? {
    switch termination {
    case .completed:
      return nil
    case .failed(let failure):
      return failure
    case .cancelled:
      return CancellationError()
    }
  }
}

// MARK: - Head classification

private extension ChatGPTResponsesAttemptEngine {
  /// A non-success head reduced to what the classifier needs: its status, its bounded `Retry-After`,
  /// and the sanitized `code`/`message` from its diagnostic body.
  struct HeadDiagnosis: Sendable {
    let status: Int
    let retryAfterSeconds: Int?
    let code: String?
    let message: String
  }

  /// What the classifier resolves a non-success head to.
  enum HeadDecision {
    case fail(ProviderError)
    case refreshThenRetry
    /// A first clean 401 whose retry budget is already spent: the credential is still advanced to
    /// `.refresh` so the fresh token rides the next turn, but this turn ends transiently rather than
    /// latching authentication — a healthy-after-refresh credential must not be reported as needing a
    /// fresh login.
    case refreshWithoutRetry
    case latchAuthenticationRequired
    case recoverStateFree
    case backoffThenRetry(Duration?)
  }

  /// Reads and sanitizes the diagnostic body, then joins the exchange. The body is already capped by
  /// the executor at the diagnostic allowance, so reading it whole holds no more than that.
  func diagnose(
    _ exchange: HTTPStreamExchange,
    redactionValues: [String]
  ) async -> HeadDiagnosis {
    var body = Data()
    do {
      for try await chunk in exchange.body {
        body.append(chunk)
      }
    } catch {
      // A diagnostic that failed to arrive whole is still classified by its status; the partial body
      // is sanitized like any other.
    }
    _ = await exchange.cancelAndAwait()

    let decoded = try? JSONDecoder().decode(ResponsesErrorBody.self, from: body)
    let rawMessage = decoded?.error?.message ?? String(data: body, encoding: .utf8) ?? ""
    let message = ChatGPTWireValues.safeRemoteDiagnostic(
      rawMessage,
      redacting: redactionValues,
      maxBytes: ChatGPTProviderMetadata.maximumDiagnosticBytes
    )
    logger.notice("chatgpt responses status \(exchange.head.statusCode)")

    return HeadDiagnosis(
      status: exchange.head.statusCode,
      retryAfterSeconds: Self.retryAfterSeconds(exchange.head),
      code: decoded?.error?.code,
      message: message
    )
  }

  /// Maps a diagnosed head to a decision, consulting the caller's budget and 401/recovery history.
  func decide(
    _ diagnosis: HeadDiagnosis,
    canRetry: Bool,
    refreshRequested: Bool,
    recoveryUsed: Bool
  ) -> HeadDecision {
    switch diagnosis.status {
    case 401:
      // A first clean 401 always refreshes the credential; a second latches, whatever the budget
      // says. When the budget is already spent the refresh still happens — advancing the credential
      // for the next turn — but this turn ends transiently rather than terminally.
      guard refreshRequested == false else {
        return .latchAuthenticationRequired
      }
      return canRetry ? .refreshThenRetry : .refreshWithoutRetry

    case 403:
      // Refreshing a valid-but-unentitled credential would change nothing, so never prompt re-login.
      return .fail(.accessDenied)

    case 429:
      let clamped = backoff.clampedRetryAfterSeconds(diagnosis.retryAfterSeconds)
      guard canRetry else {
        return .fail(.quotaLimited(retryAfterSeconds: clamped))
      }
      return .backoffThenRetry(clamped.map(Duration.seconds))

    case 408, 500..<600:
      guard canRetry else {
        return .fail(.retryable(status: diagnosis.status, message: diagnosis.message))
      }
      return .backoffThenRetry(nil)

    default:
      return terminalOrRecovery(diagnosis, canRetry: canRetry, recoveryUsed: recoveryUsed)
    }
  }

  /// The default bucket: a clean poisoned-state rejection earns one state-free recovery, counted
  /// against the budget; every other clean head is a terminal rejection.
  func terminalOrRecovery(
    _ diagnosis: HeadDiagnosis,
    canRetry: Bool,
    recoveryUsed: Bool
  ) -> HeadDecision {
    guard diagnosis.code == ChatGPTRemoteFailure.invalidEncryptedContentCode else {
      return .fail(.terminal(status: diagnosis.status, message: diagnosis.message))
    }
    // The state is poisoned, but the one recovery is already spent (or the budget is), so it can
    // never heal within this turn. Surface it as invalid replay state so a fresh session drops it.
    guard recoveryUsed == false, canRetry else {
      return .fail(.invalidProviderState)
    }
    return .recoverStateFree
  }

  static func retryAfterSeconds(_ head: HTTPStreamHead) -> Int? {
    guard let raw = head.getHeader(for: "retry-after") else {
      return nil
    }
    // Whole delta-seconds only; an HTTP-date form is not honored as a bounded hint.
    guard let seconds = Int(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
      return nil
    }
    return seconds
  }
}

// MARK: - Wire error body

/// The Responses error envelope, read only for its `code` and `message`. Anything else in it is not
/// this engine's to interpret.
private struct ResponsesErrorBody: Decodable {
  struct Inner: Decodable {
    let code: String?
    let message: String?
  }

  let error: Inner?
}
