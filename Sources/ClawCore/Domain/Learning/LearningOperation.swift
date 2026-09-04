import Foundation

/// The logical hypothesis an operation answers. Two workers or a restart must never commit two
/// results for one key at one generation. The versions are part of the identity: a rubric or
/// prompt change asks a different question about the same evidence, and the answer to the old one
/// must not be reused as the answer to the new.
public struct LearningOperationKey: Sendable, Hashable {
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let phase: LearningPhase
  /// The evaluator's sealed evidence digest, or the reflector's frozen trigger identity.
  public let sourceDigest: String
  public let promptVersion: Int
  public let schemaVersion: Int
  public let rubricVersion: Int

  public init(
    jobId: Int64,
    epoch: LearningEpoch,
    phase: LearningPhase,
    sourceDigest: String,
    promptVersion: Int,
    schemaVersion: Int,
    rubricVersion: Int
  ) {
    self.jobId = jobId
    self.epoch = epoch
    self.phase = phase
    self.sourceDigest = sourceDigest
    self.promptVersion = promptVersion
    self.schemaVersion = schemaVersion
    self.rubricVersion = rubricVersion
  }

  /// The stored form of the whole key. `learning_operations` has columns for four of the seven
  /// fields, so the digest is what a claim index can be unique on.
  public var digest: LearningOperationKeyDigest {
    let fields = [
      Self.canonicalPrefix,
      String(jobId),
      String(epoch.value),
      phase.rawValue,
      sourceDigest,
      String(promptVersion),
      String(schemaVersion),
      String(rubricVersion),
    ]
    let canonical = CanonicalDigestInput.joined(fields)
    return LearningOperationKeyDigest(rawValue: SHA256Digest.hex(canonical))
  }

  /// Frozen into every key digest. A change to the field list below must change this value too, so
  /// old rows keep answering the question they were claimed for.
  private static let canonicalPrefix = "learning-operation/v1"
}

/// One durable attempt at a key. Two attempts at one key are two rows joined by `supersedes`, never
/// one row rewritten: the earlier attempt's provider-call id has to stay readable and unreused.
public struct ClaimedOperation: Sendable, Equatable {
  public let id: LearningOperationID
  public let key: LearningOperationKey
  public let attemptGeneration: Int
  /// The `interrupted_unknown` attempt this generation replaces, if any.
  public let supersedes: LearningOperationID?

  public init(
    id: LearningOperationID,
    key: LearningOperationKey,
    attemptGeneration: Int,
    supersedes: LearningOperationID?
  ) {
    self.id = id
    self.key = key
    self.attemptGeneration = attemptGeneration
    self.supersedes = supersedes
  }
}

/// The privacy decision over the exact bytes about to be sent, recomputed by the caller
/// immediately before authorization rather than carried forward from the claim.
public struct CarrierAuthorization: Sendable, Equatable {
  /// What the carrier was actually assembled from. The authorization transaction compares it
  /// against the operation's own source, so a carrier built from another run's evidence cannot be
  /// sent under this operation's identity.
  public let sourceDigest: String
  public let digest: CarrierDigest
  public let isPermitted: Bool

  public init(sourceDigest: String, digest: CarrierDigest, isPermitted: Bool) {
    self.sourceDigest = sourceDigest
    self.digest = digest
    self.isPermitted = isPermitted
  }
}

/// Everything the authorize-and-start transaction needs to decide and record in one commit. The
/// budget gate travels with the request because the policy belongs to the caller, while the totals
/// it is applied to may only be read inside the transaction that writes the reservation.
public struct LearningAuthorization: Sendable {
  public let operationId: LearningOperationID
  public let carrier: CarrierAuthorization
  public let estimatedTokens: Int
  public let estimatedCostUSD: Double
  public let configuredRoute: String
  public let providerCallID: ProviderCallID
  public let budget: BudgetGate
  public let context: LearningAuthorizationContext

  public init(
    operationId: LearningOperationID,
    carrier: CarrierAuthorization,
    estimatedTokens: Int,
    estimatedCostUSD: Double,
    configuredRoute: String,
    providerCallID: ProviderCallID,
    budget: BudgetGate,
    context: LearningAuthorizationContext = .evaluation
  ) {
    self.operationId = operationId
    self.carrier = carrier
    self.estimatedTokens = estimatedTokens
    self.estimatedCostUSD = estimatedCostUSD
    self.configuredRoute = configuredRoute
    self.providerCallID = providerCallID
    self.budget = budget
    self.context = context
  }
}

/// Phase-specific state the authorize transaction must revalidate immediately before the network.
/// Evaluation has no wider frozen window; reflection must still describe the exact source edges.
public enum LearningAuthorizationContext: Sendable, Equatable {
  case evaluation
  case reflection(ReflectionAuthorization)
}

public struct ReflectionAuthorization: Sendable, Equatable {
  public let trigger: TriggerIdentity
  public let stableRevision: StableRevision
  public let evidence: [CandidateEvidenceSource]
  public let evaluations: [CandidateEvaluationSource]
  public let feedback: [CandidateFeedbackSource]

  public init(
    trigger: TriggerIdentity,
    stableRevision: StableRevision,
    evidence: [CandidateEvidenceSource],
    evaluations: [CandidateEvaluationSource],
    feedback: [CandidateFeedbackSource]
  ) {
    self.trigger = trigger
    self.stableRevision = stableRevision
    self.evidence = evidence
    self.evaluations = evaluations
    self.feedback = feedback
  }

  public init(preparation: ReflectionPreparation) {
    self.init(
      trigger: preparation.trigger,
      stableRevision: preparation.stableRevision,
      evidence: preparation.evidenceSources,
      evaluations: preparation.evaluationSources,
      feedback: preparation.feedbackSources
    )
  }
}

/// What one authorization decided. Only `.started` permits a network call.
public enum AuthorizeOutcome: Sendable, Equatable {
  case started
  /// Closed terminally without ever reaching the network.
  case deniedNoCall(LearningOperationFailure)
  /// The claim no longer describes work worth doing — the job re-epoched, or another transaction
  /// already moved the row out of `claimed`. Nothing is written: no call was refused by policy, so
  /// no policy verdict is recorded against it.
  case superseded
}

/// Whether an operation still holds budget it has not spent. A row that never authorized carries
/// no reservation at all, which is why the stored column is nullable.
public enum LearningReservationState: String, Sendable, Equatable {
  case open
  case closed
}

/// What the provider call actually billed, as the result commit records it.
public struct LearningCallUsage: Sendable, Equatable {
  /// The route that actually served the call, in the same vocabulary `provider_usage.model`
  /// carries for every other call.
  public let model: String
  public let promptTokens: Int
  public let completionTokens: Int
  public let costUSD: Double
  public let costSource: CostSource
  public let isEstimated: Bool

  public init(
    model: String,
    promptTokens: Int,
    completionTokens: Int,
    costUSD: Double,
    costSource: CostSource,
    isEstimated: Bool
  ) {
    self.model = model
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.costUSD = costUSD
    self.costSource = costSource
    self.isEstimated = isEstimated
  }

  /// What the shared accounting authority resolved, in the learning shape. There is no row
  /// identity here on purpose: the result commit charges under the call id its own reservation
  /// holds, pins `run_id` to null and re-derives the session from the job, so a caller that
  /// supplied any of those would be writing values nothing reads back.
  public init(model: String, resolved: ProviderUsageAccountant.Resolved) {
    self.init(
      model: model,
      promptTokens: resolved.usage.usage.promptTokens,
      completionTokens: resolved.usage.usage.completionTokens,
      costUSD: resolved.cost.costUSD,
      costSource: resolved.cost.source,
      isEstimated: resolved.usage.isEstimated || resolved.cost.isEstimated
    )
  }
}

/// The evaluator's verdict on one run's sealed evidence, as the result commit records it.
public struct LearningEvaluation: Sendable, Equatable {
  public let outcome: EvaluatorOutcome
  /// Stored sorted and compared by exact equality: two runs report the same defect only when their
  /// codes match character for character, so an arrival order must never change the comparison.
  public let issueCodes: [String]
  public let evaluator: EvaluatorSurface

  /// Sorts on the way in, so no caller can put an arrival order into the durable form.
  public init(outcome: EvaluatorOutcome, issueCodes: [String], evaluator: EvaluatorSurface) {
    self.outcome = outcome
    self.issueCodes = issueCodes.sorted()
    self.evaluator = evaluator
  }
}

public struct NoCandidateResult: Sendable, Equatable {
  public let algorithm: LearningAlgorithm
  public let triggerDigest: TriggerDigest
  public let operationId: LearningOperationID
  public let carrierDigest: CarrierDigest
  public let resultDigest: ReflectionResultDigest
  public let authorization: ReflectionAuthorization

  public init(
    algorithm: LearningAlgorithm,
    triggerDigest: TriggerDigest,
    operationId: LearningOperationID,
    carrierDigest: CarrierDigest,
    resultDigest: ReflectionResultDigest,
    authorization: ReflectionAuthorization
  ) {
    self.algorithm = algorithm
    self.triggerDigest = triggerDigest
    self.operationId = operationId
    self.carrierDigest = carrierDigest
    self.resultDigest = resultDigest
    self.authorization = authorization
  }
}

/// The one phase-valid product of a completed crossing. The enum makes two semantic products at
/// once unrepresentable; failure is terminal spend with no artifact or receipt.
public enum LearningOperationProduct: Sendable, Equatable {
  case failure(LearningOperationFailure)
  case evaluation(LearningEvaluation)
  case candidate(CandidateArtifact)
  case noCandidate(NoCandidateResult)

  public var failure: LearningOperationFailure? {
    guard case .failure(let failure) = self else {
      return nil
    }
    return failure
  }
}

/// One network boundary crossing, closed. Every product travels with the result because a
/// finished key is never reopened after an ordinary completed generation.
public struct LearningOperationResult: Sendable, Equatable {
  public let operationId: LearningOperationID
  public let usage: LearningCallUsage
  public let product: LearningOperationProduct

  public init(
    operationId: LearningOperationID,
    usage: LearningCallUsage,
    product: LearningOperationProduct
  ) {
    self.operationId = operationId
    self.usage = usage
    self.product = product
  }
}

/// The learning scope on a `provider_usage` row. A learning call belongs to no run, so without
/// this pair its spend cannot reach the origin-filtered proactive total the algorithm charges.
public struct LearningUsageScope: Sendable, Equatable {
  public let operationId: LearningOperationID
  public let jobId: Int64

  public init(operationId: LearningOperationID, jobId: Int64) {
    self.operationId = operationId
    self.jobId = jobId
  }
}

/// What one boot pass did to the operations a prior process left open.
public struct OperationReconciliation: Sendable, Equatable {
  /// `started` rows: a provider call may have gone out, so each is charged conservatively and
  /// closed as `interrupted_unknown`.
  public let interrupted: Int
  /// `claimed` rows: durable state proves no call started, so each returns to `pending`.
  public let returnedToClaimable: Int

  public init(interrupted: Int, returnedToClaimable: Int) {
    self.interrupted = interrupted
    self.returnedToClaimable = returnedToClaimable
  }
}
