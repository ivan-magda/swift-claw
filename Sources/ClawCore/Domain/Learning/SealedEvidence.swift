import Foundation

/// Policy the accepted algorithm requires to exist but declines to name. Both bounds are part of
/// `EligibilityClassifier.version`: `finalOutputByteCap` decides which runs reach the evaluator at
/// all, so changing either value changes the classification of runs already sealed under the old
/// one. Bump the classifier version in the same edit, so a new compatibility window opens rather
/// than old receipts being silently reinterpreted.
public enum EvidenceLimits {
  /// The evaluator reads the final answer whole or not at all. A run whose answer exceeds this is
  /// classified `insufficientEvidence` rather than sealed truncated, because a clipped answer would
  /// read to the evaluator as the model's own and manufacture a behavioral issue that never
  /// happened.
  public static let finalOutputByteCap = 32_768

  /// Ordered tool facts kept per run. Bounds one runaway agent loop's evidence row; the count of
  /// proposed and observed calls is recorded separately, so a run past the bound is still known to
  /// be complete.
  public static let maxToolFacts = 64

  /// The version of the payload shape below. Frozen onto every receipt: a change to the fields the
  /// evaluator sees opens a new compatibility window.
  public static let schemaVersion = "evidence/v1"
}

/// The persisted shape of one run's transcript, reduced to the three facts eligibility turns on.
/// Derived from the message rows, never from live agent state.
public struct EvidenceTranscript: Sendable, Equatable {
  public let proposedCalls: Int
  public let observedCalls: Int
  public let finalOutputBytes: Int

  public init(proposedCalls: Int, observedCalls: Int, finalOutputBytes: Int) {
    self.proposedCalls = proposedCalls
    self.observedCalls = observedCalls
    self.finalOutputBytes = finalOutputBytes
  }

  /// Whether the persisted rows still describe the whole run. Without an independent tool-lifecycle
  /// log this shape is the only signal there is: proposed calls sit in the assistant row while the
  /// observation rows that answered them are missing.
  public var isReconstructable: Bool {
    observedCalls >= proposedCalls && finalOutputBytes <= EvidenceLimits.finalOutputByteCap
  }

  /// A run that proposed nothing, so nothing can be missing — the shape a plain answered turn
  /// leaves behind.
  public static let complete = EvidenceTranscript(
    proposedCalls: 0,
    observedCalls: 0,
    finalOutputBytes: 0
  )
}

/// One tool call as evidence: that it was proposed, in which order, and whether an observation ever
/// answered it. Never the arguments — those carry paths, destinations and owner data the evaluator
/// has no business reading.
public struct EvidenceToolFact: Sendable, Equatable, Codable {
  public let ordinal: Int
  public let name: String
  public let observed: Bool

  public init(ordinal: Int, name: String, observed: Bool) {
    self.ordinal = ordinal
    self.name = name
    self.observed = observed
  }
}

/// What the evaluator is allowed to see: the run's own answer, the bounded shape of how it got
/// there, and the frozen surface it ran on. It deliberately excludes raw tool arguments, secrets,
/// private raw observations, replay state and audit projections.
public struct EvidencePayload: Sendable, Equatable, Codable {
  public let schemaVersion: String
  public let jobDefinitionDigest: String
  public let effectiveLessonSetDigest: String
  public let sourceMessageId: Int64
  public let sourceDigest: String
  public let finalOutput: String
  public let toolFacts: [EvidenceToolFact]
  public let proposedCalls: Int
  public let observedCalls: Int
  /// Copied off `run_compatibility`, which froze them at pickup. Never re-read from the live
  /// workspace, tool catalog or route at sealing time.
  public let contextSchemaVersion: String
  public let toolCatalogDigest: String
  public let policyVersion: String
  public let skillSetDigest: String
  public let configuredRoute: String
  public let terminalRoute: String?
  public let usageRowIds: [Int64]

  public init(  // swiftlint:disable:this function_parameter_count
    schemaVersion: String,
    jobDefinitionDigest: String,
    effectiveLessonSetDigest: String,
    sourceMessageId: Int64,
    sourceDigest: String,
    finalOutput: String,
    toolFacts: [EvidenceToolFact],
    proposedCalls: Int,
    observedCalls: Int,
    contextSchemaVersion: String,
    toolCatalogDigest: String,
    policyVersion: String,
    skillSetDigest: String,
    configuredRoute: String,
    terminalRoute: String?,
    usageRowIds: [Int64]
  ) {
    self.schemaVersion = schemaVersion
    self.jobDefinitionDigest = jobDefinitionDigest
    self.effectiveLessonSetDigest = effectiveLessonSetDigest
    self.sourceMessageId = sourceMessageId
    self.sourceDigest = sourceDigest
    self.finalOutput = finalOutput
    self.toolFacts = toolFacts
    self.proposedCalls = proposedCalls
    self.observedCalls = observedCalls
    self.contextSchemaVersion = contextSchemaVersion
    self.toolCatalogDigest = toolCatalogDigest
    self.policyVersion = policyVersion
    self.skillSetDigest = skillSetDigest
    self.configuredRoute = configuredRoute
    self.terminalRoute = terminalRoute
    self.usageRowIds = usageRowIds
  }
}

/// Why a run that reached the sealer carries no payload at all. Distinct from an eligibility value:
/// eligibility says what the run's outcome means, an exclusion says the run cannot be filed as
/// evidence about this job's current work in the first place.
public enum EvidenceExclusion: String, Sendable, Equatable, CaseIterable {
  /// No learning binding — a heartbeat, a fire under a disarmed daemon, or a run that predates
  /// bindings. There is no job or epoch to file a receipt under, so none is written.
  case legacyUnbound = "legacy_unbound"
  /// The job moved to a later epoch after this run fired. The tombstone records that the run was
  /// seen and closed; its evidence never rejoins the loop.
  case staleEpoch = "stale_epoch"
  /// The run never froze a compatibility surface, or the frozen row no longer reads back. The
  /// sealer files the run under the surface it ran on or under nothing — never under today's.
  case compatibilityUnavailable = "compatibility_unavailable"
  /// The lesson set the run actually ran against no longer resolves, so what the run was told
  /// cannot be reconstructed.
  case sourceDigestUnresolved = "source_digest_unresolved"
}

/// One sealed `learning_evidence` row: the eligibility receipt always, the payload only when the
/// run is task evidence the evaluator may read.
public struct SealedEvidence: Sendable, Equatable {
  public let runId: Int64
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let digest: EvidenceDigest
  public let eligibility: LearningEligibility
  public let classifierVersion: String
  public let exclusion: EvidenceExclusion?
  /// Nil for an ineligible or excluded run, and nil again once the 30-day payload sweep has run
  /// while the compact receipt around it lives on.
  public let payload: EvidencePayload?
  public let sealedAt: Date

  public init(
    runId: Int64,
    jobId: Int64,
    epoch: LearningEpoch,
    digest: EvidenceDigest,
    eligibility: LearningEligibility,
    classifierVersion: String,
    exclusion: EvidenceExclusion?,
    payload: EvidencePayload?,
    sealedAt: Date
  ) {
    self.runId = runId
    self.jobId = jobId
    self.epoch = epoch
    self.digest = digest
    self.eligibility = eligibility
    self.classifierVersion = classifierVersion
    self.exclusion = exclusion
    self.payload = payload
    self.sealedAt = sealedAt
  }
}

/// What one call to `sealEvidence` did. Every case is a stopping point: the sealer is idempotent
/// and keyed by `run_id`, so a second notification for the same run writes nothing.
public enum SealOutcome: Sendable, Equatable {
  case sealed(eligibility: LearningEligibility)
  /// A content-free tombstone, or — for `legacyUnbound`, which has no job to file under — no row at
  /// all. Either way the run is closed and never sealed again.
  case excluded(EvidenceExclusion)
  case alreadySealed
  /// The run is not terminal, or is terminal with a primary fact still owed. Its facts can still
  /// change, so there is nothing to freeze yet.
  case notSettled
}
