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
    return LearningOperationKeyDigest(rawValue: SHA256Digest.hex(fields.joined(separator: ":")))
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

  public init(
    operationId: LearningOperationID,
    carrier: CarrierAuthorization,
    estimatedTokens: Int,
    estimatedCostUSD: Double,
    configuredRoute: String,
    providerCallID: ProviderCallID,
    budget: BudgetGate
  ) {
    self.operationId = operationId
    self.carrier = carrier
    self.estimatedTokens = estimatedTokens
    self.estimatedCostUSD = estimatedCostUSD
    self.configuredRoute = configuredRoute
    self.providerCallID = providerCallID
    self.budget = budget
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
}

/// One network boundary crossing, closed. `failure` nil means the call returned output the
/// operation can use; a failure means it returned something it cannot, which is still spend.
public struct LearningOperationResult: Sendable, Equatable {
  public let operationId: LearningOperationID
  public let failure: LearningOperationFailure?
  public let usage: LearningCallUsage

  public init(
    operationId: LearningOperationID,
    failure: LearningOperationFailure?,
    usage: LearningCallUsage
  ) {
    self.operationId = operationId
    self.failure = failure
    self.usage = usage
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
