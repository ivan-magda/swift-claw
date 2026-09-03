import ClawAgent
import ClawCore
import Foundation
import Logging

/// Drives one learning inference from a sealed receipt to a committed verdict. Every hop it makes
/// is a refusal point: the claim, the privacy check over the exact bytes, and the
/// authorize-and-start transaction that owns the breakers. Nothing reaches the network until that
/// transaction says `.started`, and whatever comes back is committed exactly once.
///
/// It dispatches through the `ProviderRoster` rather than a bare provider so a learning call obeys
/// the same primary-to-fallback selection and route cooldown a turn does. A call holding one
/// provider handle would keep probing a plan the roster has already walled off, and it would have
/// no honest served route to record — which the compatibility digest hashes.
public struct LearningOperationRunner: Sendable {
  /// The evaluator's whole reply is one small JSON object, and the frozen algorithm bounds it here
  /// rather than at the route's own ceiling.
  public static let evaluatorOutputTokenCap = 512
  private static let carrierLabel = "evaluation-record"

  private let learning: any ScheduledLearningStore
  private let jobs: any ScheduledJobStore
  private let roster: ProviderRoster
  /// The primary's cooldown window, shared with the turn path so a route that just walled off a
  /// turn is not re-probed by background learning work. Absent when nothing composed one.
  private let cooldown: (any PrimaryRouteCooldownTracking)?
  private let budget: RunBudget
  private let costResolver: CostResolver
  /// Applied to the exact serialized carrier, not to any field of it: the decision is over the
  /// bytes that would go out.
  private let redactor: SecretRedactor
  private let providerCallIDGenerator: any ProviderCallIDGenerating
  private let logger: Logger

  public init(
    learning: any ScheduledLearningStore,
    jobs: any ScheduledJobStore,
    roster: ProviderRoster,
    cooldown: (any PrimaryRouteCooldownTracking)? = nil,
    budget: RunBudget,
    costResolver: CostResolver,
    redactor: SecretRedactor = SecretRedactor(secretValues: []),
    providerCallIDGenerator: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator(),
    logger: Logger
  ) {
    self.learning = learning
    self.jobs = jobs
    self.roster = roster
    self.cooldown = cooldown
    self.budget = budget
    self.costResolver = costResolver
    self.redactor = redactor
    self.providerCallIDGenerator = providerCallIDGenerator
    self.logger = logger
  }

  /// One evaluation of one run, or nothing at all. Never throws: a run the evaluator cannot judge
  /// must not disturb the pass that asked for it, let alone ordinary scheduled execution.
  public func runEvaluation(runId: Int64, now: Date) async {
    do {
      try await evaluate(runId: runId, now: now)
    } catch {
      logger.error("run \(runId) could not be evaluated: \(error)")
    }
  }
}

// MARK: - Evaluation Sequence

private extension LearningOperationRunner {
  func evaluate(runId: Int64, now: Date) async throws {
    guard
      let evidence = try learning.evidence(runId: runId),
      evidence.eligibility.reachesEvaluator,
      let payload = evidence.payload,
      let job = try jobs.job(id: evidence.jobId),
      let sessionId = job.sessionId
    else {
      return
    }
    guard let claim = try learning.claimOperation(Self.key(for: evidence), now: now) else {
      return
    }

    let carrier = EvaluatorCarrier(
      runId: runId,
      jobPrompt: job.prompt,
      rubric: EvaluatorRubric.v1.text,
      evidence: payload
    )
    let bytes = try CanonicalJSON.data(encoding: carrier)
    // Lossless, not failable: these are `JSONEncoder` bytes, so a failable conversion here would
    // add a branch that can never be taken and a fallback that would have to invent a carrier.
    // swiftlint:disable:next optional_data_string_conversion
    let serialized = String(decoding: bytes, as: UTF8.self)
    let messages = Self.messages(carrier: serialized)

    let route = roster.startingRoute(primaryIsCooling: await cooldown?.isCooling() == true)
    let call = Call(
      operationId: claim.id,
      callID: providerCallIDGenerator.next(),
      sessionId: sessionId,
      messages: messages
    )
    let authorized = try authorize(
      call,
      route: route,
      carrier: CarrierAuthorization(
        sourceDigest: evidence.digest.rawValue,
        digest: CarrierDigest(rawValue: SHA256Digest.hex(bytes)),
        // A carrier whose redaction changes its bytes is denied, never sent scrubbed: a scrubbed
        // answer is no longer the answer the run gave, and judging it would manufacture a defect.
        isPermitted: redactor.redact(serialized) == serialized
      ),
      now: now
    )
    guard authorized else {
      return
    }
    await dispatch(call, starting: route, now: now)
  }

  /// The last gate before the network. `.superseded` is neither a failure nor a verdict: the claim
  /// stopped describing work worth doing, so nothing is written and nothing is logged as an error.
  func authorize(
    _ call: Call,
    route: RouteSelection,
    carrier: CarrierAuthorization,
    now: Date
  ) throws -> Bool {
    let estimate = accountant(for: route.binding).preflightEstimate(context: call.messages)
    let authorization = LearningAuthorization(
      operationId: call.operationId,
      carrier: carrier,
      estimatedTokens: estimate.totalTokens,
      estimatedCostUSD: estimate.costUSD,
      configuredRoute: route.binding.configuredReference,
      providerCallID: call.callID,
      budget: BudgetGate(budget: budget, costPolicy: route.binding.costPolicy)
    )
    switch try learning.authorizeAndStartOperation(authorization, now: now) {
    case .started:
      return true
    case .deniedNoCall(let failure):
      logger.info("learning call \(call.operationId.rawValue) refused: \(failure.rawValue)")
      return false
    case .superseded:
      return false
    }
  }

  /// One call, plus the single route switch a permitted cause buys it. There is no round-trip
  /// budget beyond that: a learning inference the roster cannot serve is spend the algorithm
  /// declines rather than a request to keep trying.
  func dispatch(_ call: Call, starting: RouteSelection, now: Date) async {
    var active = starting
    var request = Self.request(model: active.binding.wireModel, messages: call.messages)
    while true {
      do {
        let response = try await active.binding.provider.complete(request: request)
        if active.position == .primary {
          _ = await cooldown?.recordSuccess()
        }
        commit(response, call: call, route: active.binding, now: now)
        return
      } catch {
        guard
          let persistence = RouteSwitch.permits(error),
          let next = roster.failover(from: active.position)
        else {
          commit(failure: error, call: call, route: active.binding, now: now)
          return
        }
        await cooldown?.arm(
          persistence: persistence,
          retryAfterSeconds: RouteSwitch.retryAfterSeconds(of: error)
        )
        active = next
        request = Self.request(model: active.binding.wireModel, messages: call.messages)
      }
    }
  }
}

// MARK: - Result Commit

private extension LearningOperationRunner {
  /// A reply outside the frozen schema is terminal spend, not a prompt to ask again: there is no
  /// schema-repair call, so the operation closes `schema_invalid` with the call it already paid for.
  func commit(_ response: ChatResponse, call: Call, route: LLMRouteBinding, now: Date) {
    let usage = accountant(for: route).reconciledRow(
      for: response,
      callID: call.callID,
      context: call.messages,
      runId: nil,
      sessionId: call.sessionId
    )
    let output: EvaluatorOutput
    do {
      output = try JSONDecoder().decode(EvaluatorOutput.self, from: Data(response.content.utf8))
    } catch {
      // The reason, not just the refusal: a run's evidence is unjudgeable from here on, and the
      // decoder's own message is the only record of why. It quotes the schema, never the reply.
      logger.info("learning call \(call.operationId.rawValue) returned an unusable reply: \(error)")
      finish(call, failure: .schemaInvalid, usage: usage, evaluation: nil, now: now)
      return
    }
    finish(
      call,
      failure: nil,
      usage: usage,
      evaluation: LearningEvaluation(
        outcome: output.outcome,
        issueCodes: output.issueCodes,
        evaluator: Self.surface(servedBy: route)
      ),
      now: now
    )
  }

  /// A failure the roster cannot route around still closes the operation, because the reservation
  /// it holds is real. What it is charged depends on the provider's own verdict: a call that may
  /// have generated tokens owes the conservative estimate, and a proven `notStarted` owes nothing.
  func commit(failure error: any Error, call: Call, route: LLMRouteBinding, now: Date) {
    let usage: ProviderUsage
    switch ProviderFailureAccounting.classify(error) {
    case .mayHaveStarted(let observedCompletionTokens):
      usage = accountant(for: route).conservativeRow(
        callID: call.callID,
        context: call.messages,
        observedCompletionTokens: observedCompletionTokens,
        runId: nil,
        sessionId: call.sessionId
      )
    case .notStarted:
      usage = ProviderUsage(
        providerCallID: call.callID,
        runId: nil,
        sessionId: call.sessionId,
        model: route.configuredReference,
        promptTokens: 0,
        completionTokens: 0,
        costUSD: 0,
        costSource: .providerReturned,
        isEstimated: false,
        ts: now
      )
    }
    logger.info("learning call \(call.operationId.rawValue) failed at the provider: \(error)")
    finish(call, failure: .providerTerminal, usage: usage, evaluation: nil, now: now)
  }

  /// The verdict rides the same commit as the operation's terminal state. A `succeeded` row whose
  /// verdict landed in a later transaction could lose it to a crash, and `claim` refuses a finished
  /// key forever — so that run's evidence would be paid for and permanently unjudgeable.
  func finish(
    _ call: Call,
    failure: LearningOperationFailure?,
    usage: ProviderUsage,
    evaluation: LearningEvaluation?,
    now: Date
  ) {
    do {
      _ = try learning.finishOperation(
        LearningOperationResult(
          operationId: call.operationId,
          failure: failure,
          usage: LearningCallUsage(usage),
          evaluation: evaluation
        ),
        now: now
      )
    } catch {
      // Boot reconciliation is the backstop: the row is still `started`, so the next start charges
      // it conservatively under its saved call id and closes it as interrupted.
      logger.error("learning call \(call.operationId.rawValue) could not be committed: \(error)")
    }
  }
}

// MARK: - Call Shapes

private extension LearningOperationRunner {
  /// The identities one crossing needs in every arm of the dispatch, kept together so a retry on
  /// another route cannot quietly mint a second call id for the same reservation.
  struct Call {
    let operationId: LearningOperationID
    let callID: ProviderCallID
    let sessionId: Int64
    let messages: [ChatMessage]
  }

  static func key(for evidence: SealedEvidence) -> LearningOperationKey {
    LearningOperationKey(
      jobId: evidence.jobId,
      epoch: evidence.epoch,
      phase: .evaluator,
      sourceDigest: evidence.digest.rawValue,
      promptVersion: EvaluatorPrompt.v1.version,
      schemaVersion: EvaluatorOutput.currentSchemaVersion,
      rubricVersion: EvaluatorRubric.v1.version
    )
  }

  static func surface(servedBy route: LLMRouteBinding) -> EvaluatorSurface {
    EvaluatorSurface(
      route: route.configuredReference,
      promptVersion: EvaluatorPrompt.v1.version,
      schemaVersion: EvaluatorOutput.currentSchemaVersion,
      rubricVersion: EvaluatorRubric.v1.version
    )
  }

  /// The carrier travels fenced: every field of it is model-written or owner-written text, so it is
  /// data to judge and never instructions the evaluator may act on.
  static func messages(carrier: String) -> [ChatMessage] {
    let fenced = LabeledContextFactory.make(label: carrierLabel, content: carrier).render()
    return [
      ChatMessage(role: .system, content: EvaluatorPrompt.v1.text),
      ChatMessage(role: .user, content: fenced),
    ]
  }

  static func request(model: String, messages: [ChatMessage]) -> ChatRequest {
    // No tools, ever: a judging call that could act would stop being a judgement, and the frozen
    // algorithm gives the evaluator nothing to act with.
    ChatRequest(
      model: model,
      messages: messages,
      maxOutputTokens: evaluatorOutputTokenCap,
      tools: []
    )
  }

  func accountant(for route: LLMRouteBinding) -> ProviderUsageAccountant {
    ProviderUsageAccountant(
      configuredReference: route.configuredReference,
      costPolicy: route.costPolicy,
      reservationPolicy: route.reservationPolicy,
      costResolver: costResolver,
      outputCap: Self.evaluatorOutputTokenCap
    )
  }
}
