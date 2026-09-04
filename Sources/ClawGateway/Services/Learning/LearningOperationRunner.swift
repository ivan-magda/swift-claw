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

  let learning: any ScheduledLearningStore
  let jobs: any ScheduledJobStore
  let roster: ProviderRoster
  /// The primary's cooldown window, shared with the turn path so a route that just walled off a
  /// turn is not re-probed by background learning work. Absent when nothing composed one.
  let cooldown: (any PrimaryRouteCooldownTracking)?
  let budget: RunBudget
  let costResolver: CostResolver
  /// Applied to the exact serialized carrier, not to any field of it: the decision is over the
  /// bytes that would go out. Deliberately not defaulted: an empty redactor makes the whole check
  /// inert, and a composition root that forgot the argument would put every run's final output on
  /// the wire with nothing to catch it.
  let redactor: SecretRedactor
  let providerCallIDGenerator: any ProviderCallIDGenerating
  let logger: Logger

  public init(
    learning: any ScheduledLearningStore,
    jobs: any ScheduledJobStore,
    roster: ProviderRoster,
    cooldown: (any PrimaryRouteCooldownTracking)? = nil,
    budget: RunBudget,
    costResolver: CostResolver,
    redactor: SecretRedactor,
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
      // A job that has never fired has no session for the result commit to charge against. It
      // cannot own a settled bound run either, so this refuses before the claim rather than
      // leaving a `started` row for boot to charge conservatively.
      job.sessionId != nil
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
    let usage = LearningCallUsage(
      model: route.configuredReference,
      resolved: accountant(for: route).reconciled(for: response, context: call.messages)
    )
    let output: EvaluatorOutput
    do {
      // Unfenced first. A model that wrapped its object in a code fence answered the question we
      // asked; failing it here would close the key forever over punctuation, and `claim` never
      // reopens a finished one.
      let reply = FencedJSONReply.unfenced(response.content)
      output = try JSONDecoder().decode(EvaluatorOutput.self, from: Data(reply.utf8))
    } catch {
      // The reason, not just the refusal: a run's evidence is unjudgeable from here on, and the
      // decoder's own message is the only record of why. It quotes the schema, never the reply.
      logger.info("learning call \(call.operationId.rawValue) returned an unusable reply: \(error)")
      finish(call, usage: usage, product: .failure(.schemaInvalid), now: now)
      return
    }
    finish(
      call,
      usage: usage,
      product: .evaluation(
        LearningEvaluation(
          outcome: output.outcome,
          issueCodes: output.issueCodes,
          evaluator: Self.surface(servedBy: route)
        )
      ),
      now: now
    )
  }

  /// A failure the roster cannot route around still closes the operation, because the reservation
  /// it holds is real. What it is charged depends on the provider's own verdict: a call that may
  /// have generated tokens owes the conservative estimate, and a proven `notStarted` owes nothing.
  func commit(failure error: any Error, call: Call, route: LLMRouteBinding, now: Date) {
    let usage: LearningCallUsage
    switch ProviderFailureAccounting.classify(error) {
    case .mayHaveStarted(let observedCompletionTokens):
      usage = LearningCallUsage(
        model: route.configuredReference,
        resolved: accountant(for: route).conservative(
          context: call.messages,
          observedCompletionTokens: observedCompletionTokens
        )
      )
    case .notStarted:
      // A confirmed zero, not a guess: the provider proved it generated nothing, which is what
      // `providerReturned` at $0 means everywhere else in the tree.
      usage = LearningCallUsage(
        model: route.configuredReference,
        promptTokens: 0,
        completionTokens: 0,
        costUSD: 0,
        costSource: .providerReturned,
        isEstimated: false
      )
    }
    logger.info("learning call \(call.operationId.rawValue) failed at the provider: \(error)")
    finish(call, usage: usage, product: .failure(.providerTerminal), now: now)
  }

  /// The verdict rides the same commit as the operation's terminal state. A `succeeded` row whose
  /// verdict landed in a later transaction could lose it to a crash, and `claim` refuses a finished
  /// key forever — so that run's evidence would be paid for and permanently unjudgeable.
  func finish(
    _ call: Call,
    usage: LearningCallUsage,
    product: LearningOperationProduct,
    now: Date
  ) {
    do {
      _ = try learning.finishOperation(
        LearningOperationResult(
          operationId: call.operationId,
          usage: usage,
          product: product
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
