import Foundation

/// A single-use authenticated address for one exact feedback subject.
public struct NewFeedbackTarget: Sendable, Equatable {
  public let nonce: String
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let subjectKind: FeedbackSubjectKind
  public let subjectDigest: String
  public let allowedActions: [OwnerSignal]
  public let ownerUserId: Int64
  public let chatId: Int64
  public let expiresAt: Date

  public init(
    nonce: String,
    jobId: Int64,
    epoch: LearningEpoch,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String,
    allowedActions: [OwnerSignal],
    ownerUserId: Int64,
    chatId: Int64,
    expiresAt: Date
  ) {
    self.nonce = nonce
    self.jobId = jobId
    self.epoch = epoch
    self.subjectKind = subjectKind
    self.subjectDigest = subjectDigest
    self.allowedActions = allowedActions
    self.ownerUserId = ownerUserId
    self.chatId = chatId
    self.expiresAt = expiresAt
  }
}

/// The durable target returned by nonce lookup. `targetId` never crosses the transport boundary.
public struct FeedbackTarget: Sendable, Equatable {
  public let targetId: Int64
  public let nonce: String
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let subjectKind: FeedbackSubjectKind
  public let subjectDigest: String
  public let allowedActions: [OwnerSignal]
  public let ownerUserId: Int64
  public let chatId: Int64
  public let expiresAt: Date
  public let consumedAt: Date?

  public init(
    targetId: Int64,
    nonce: String,
    jobId: Int64,
    epoch: LearningEpoch,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String,
    allowedActions: [OwnerSignal],
    ownerUserId: Int64,
    chatId: Int64,
    expiresAt: Date,
    consumedAt: Date?
  ) {
    self.targetId = targetId
    self.nonce = nonce
    self.jobId = jobId
    self.epoch = epoch
    self.subjectKind = subjectKind
    self.subjectDigest = subjectDigest
    self.allowedActions = allowedActions
    self.ownerUserId = ownerUserId
    self.chatId = chatId
    self.expiresAt = expiresAt
    self.consumedAt = consumedAt
  }
}

/// The row inserted after a feedback target has passed its authenticated single-use CAS.
public struct NewFeedbackChallenge: Sendable, Equatable {
  public let ownerUserId: Int64
  public let chatId: Int64
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let subjectKind: FeedbackSubjectKind
  public let subjectDigest: String
  public let promptDigest: String
  public let expiresAt: Date

  public init(target: FeedbackTarget) {
    ownerUserId = target.ownerUserId
    chatId = target.chatId
    jobId = target.jobId
    epoch = target.epoch
    subjectKind = target.subjectKind
    subjectDigest = target.subjectDigest
    promptDigest = FeedbackChallengeDeliveryIdentity.digest(targetNonce: target.nonce)
    expiresAt = target.expiresAt
  }
}

/// The durable one-shot owner input slot. Only an unsuperseded, unconsumed row is live.
public struct FeedbackChallenge: Sendable, Equatable {
  public let id: Int64
  public let ownerUserId: Int64
  public let chatId: Int64
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let subjectKind: FeedbackSubjectKind
  public let subjectDigest: String
  public let supersededBy: Int64?
  public let consumedAt: Date?
  public let expiresAt: Date

  public init(
    id: Int64,
    ownerUserId: Int64,
    chatId: Int64,
    jobId: Int64,
    epoch: LearningEpoch,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String,
    supersededBy: Int64?,
    consumedAt: Date?,
    expiresAt: Date
  ) {
    self.id = id
    self.ownerUserId = ownerUserId
    self.chatId = chatId
    self.jobId = jobId
    self.epoch = epoch
    self.subjectKind = subjectKind
    self.subjectDigest = subjectDigest
    self.supersededBy = supersededBy
    self.consumedAt = consumedAt
    self.expiresAt = expiresAt
  }
}

/// A prompt gets its own opaque delivery identity, separate from both subject and target nonce.
public enum FeedbackChallengeDeliveryIdentity {
  private static let domain = "feedback-challenge-prompt/v1"

  public static func digest(targetNonce: String) -> String {
    SHA256Digest.hex(CanonicalDigestInput.joined([domain, targetNonce]))
  }
}

/// The already transport-claimed owner action the store revalidates and commits atomically.
public struct FeedbackTap: Sendable, Equatable {
  public let nonce: String
  public let signal: OwnerSignal
  public let ownerUserId: Int64
  public let chatId: Int64
  public let transportUpdateId: Int64

  public init(
    nonce: String,
    signal: OwnerSignal,
    ownerUserId: Int64,
    chatId: Int64,
    transportUpdateId: Int64
  ) {
    self.nonce = nonce
    self.signal = signal
    self.ownerUserId = ownerUserId
    self.chatId = chatId
    self.transportUpdateId = transportUpdateId
  }
}

/// Every result of the target CAS. Only `recorded` appended a semantic event and revision.
public enum FeedbackOutcome: Sendable, Equatable {
  case recorded(FeedbackEvent)
  case challengeOpened(FeedbackChallenge)
  case targetMissing
  case ownerMismatch
  case chatMismatch
  case expired
  case actionMismatch
  case staleEpoch
  case alreadyConsumed
  case requiresPayloadChallenge
}

/// One job's learning position: which epoch it is in, which lesson set is currently stable, and
/// which revisions the frozen work under it was computed against.
public struct JobLearningState: Sendable, Equatable {
  public let jobId: Int64
  public let epoch: LearningEpoch
  public let stableDigest: LessonSetDigest
  public let stableRevision: StableRevision
  /// A denormalized convenience pointer, maintained by the trial lifecycle. `learning_trials` is
  /// authoritative — it holds the state machine and the partial unique index — so this value is
  /// never read for a correctness decision; `openTrial(jobId:)` is that read.
  public let openTrialId: Int64?
  public let feedbackRevision: FeedbackRevision

  public init(
    jobId: Int64,
    epoch: LearningEpoch,
    stableDigest: LessonSetDigest,
    stableRevision: StableRevision,
    openTrialId: Int64?,
    feedbackRevision: FeedbackRevision
  ) {
    self.jobId = jobId
    self.epoch = epoch
    self.stableDigest = stableDigest
    self.stableRevision = stableRevision
    self.openTrialId = openTrialId
    self.feedbackRevision = feedbackRevision
  }
}

public protocol ScheduledLearningStore: LearningResetApplying, Sendable {
  /// One read snapshot for the complete owner-facing learning projection. nil lists armed jobs;
  /// a positive id returns exactly one readable, unarmed, missing, or unreadable result.
  func learningView(jobId: Int64?) throws(StoreError) -> [JobLearningView]

  /// Revalidates and admits one already-persisted immutable candidate.
  func admitCandidate(
    digest: CandidateDigest,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome

  /// Creates an immutable approval successor and admits it through the common transaction.
  func approveCandidate(
    _ approval: CandidateApproval,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome

  /// Vetoes the predecessor and creates an immutable unadmitted edit successor.
  func editCandidate(
    _ edit: CandidateEdit,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome

  /// Atomically inserts every target and every runless chunk for one stable review identity.
  func commitCandidateReview(
    _ review: CandidateReviewNotice,
    now: Date
  ) throws(StoreError) -> Bool

  /// Commits every runless notice chunk and every nonce it exposes in one transaction.
  func createTargets(
    _ targets: [NewFeedbackTarget],
    chunks: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError)

  /// Exact opaque lookup. No row-id lookup exists on the feedback seam.
  func feedbackTarget(nonce: String) throws(StoreError) -> FeedbackTarget?

  /// Revalidates and consumes one target, appends its event, advances the job feedback revision,
  /// applies an immediately provable exact veto, and audits the outcome in one transaction.
  func consumeAndAppendEvent(
    _ tap: FeedbackTap,
    now: Date
  ) throws(StoreError) -> FeedbackOutcome

  /// Consumes one payload-bearing target and commits its one-shot challenge plus prompt chunks.
  func consumeAndOpenChallenge(
    _ tap: FeedbackTap,
    prompt: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) -> FeedbackOutcome

  /// Consumes the one live challenge and appends its exact UTF-8 payload as untrusted feedback.
  func consumeChallenge(
    id: Int64,
    payload: String,
    now: Date
  ) throws(StoreError) -> FeedbackOutcome

  /// Returns the physically live row. Callers apply their captured clock before claiming input.
  func liveChallenge(
    ownerUserId: Int64,
    chatId: Int64
  ) throws(StoreError) -> FeedbackChallenge?

  /// Idempotent. Inserts this job's learning state and its canonical empty lesson set together,
  /// or returns the state already there. The fire transaction calls it, so a job never fires with
  /// a binding that points at a lesson set that does not exist.
  func armJob(jobId: Int64, now: Date) throws(StoreError) -> JobLearningState

  /// Exact identity. Returns nil when the digest belongs to another job.
  func lessonSet(jobId: Int64, digest: LessonSetDigest) throws(StoreError) -> LessonSet?

  /// What the run's fire froze about its learning context. Nil for a run created without a
  /// binding — a heartbeat, a fire under a disarmed daemon, or a run that predates bindings.
  func binding(runId: Int64) throws(StoreError) -> RunLearningBinding?

  /// The job's live trial, open or draining, read from the authoritative `learning_trials` state.
  /// Nil once the trial is decided, which is also what makes a job admissible for a new candidate.
  /// Every decision about whether a trial is still live goes through here, never through
  /// `JobLearningState.openTrialId`.
  func openTrial(jobId: Int64) throws(StoreError) -> LearningTrial?

  /// Rebuilds one assignment cache from its exact durable sources and current feedback.
  func recomputeAssignment(
    runId: Int64,
    now: Date
  ) throws(StoreError) -> AssignmentRecomputation

  /// Every open-or-draining trial identity, sorted by job and trial id.
  func liveTrialIdentities() throws(StoreError) -> [LearningTrialIdentity]

  /// Reprojects one exact live cohort and applies only its open-to-draining edge.
  func reconcileTrial(
    _ identity: LearningTrialIdentity,
    now: Date
  ) throws(StoreError) -> TrialReconciliationResult

  /// The terminal receipt the transaction that won the run's state wrote. Nil for a run that never
  /// bound, or one that is still live.
  func settlement(runId: Int64) throws(StoreError) -> RunSettlement?

  /// The lane tail's deferred settlement: freezes a bound run's evidence once every primary fact
  /// has unwound. Idempotent and inert for an unbound, still-live or already-settled run, so the
  /// tail can call it unconditionally.
  ///
  /// - Returns: whether this call is the one that froze the evidence.
  @discardableResult
  func settleFromLane(runId: Int64, now: Date) throws(StoreError) -> Bool

  /// Freezes the surface a bound run is executing against, called at pickup while every value in
  /// it is still current. Insert-once and inert for an unbound run: a second call keeps the first
  /// snapshot, because a value captured later describes a surface the run never ran on.
  func freezeCompatibility(runId: Int64, surface: RunSurface) throws(StoreError)

  /// The frozen surface. Nil for a run that never froze one, which makes it unusable as evidence
  /// rather than a run to guess about.
  func compatibility(runId: Int64) throws(StoreError) -> RunCompatibility?

  /// Bound runs whose evidence is frozen and whose receipt is not yet sealed, oldest settlement
  /// first. Selects on `settled_at`, never on terminality: a terminal run with a primary fact still
  /// owed has facts that can still change.
  func unsealed(limit: Int) throws(StoreError) -> [Int64]

  /// The one idempotent sealing transaction, keyed by `run_id`. It verifies the run is bound and
  /// settled, compares the binding epoch against current job state, resolves the frozen surface and
  /// the lesson set the run ran against, classifies the run, and writes the eligibility receipt
  /// with its payload — or a content-free tombstone — in one statement group. A row already present
  /// writes nothing.
  @discardableResult
  func sealEvidence(runId: Int64, now: Date) throws(StoreError) -> SealOutcome

  /// The sealed receipt, payload included while retention still holds it.
  func evidence(runId: Int64) throws(StoreError) -> SealedEvidence?

  /// One aggregate reflection read. Nil means the frozen trigger is no longer authoritative: its
  /// job, base, revisions, source edges, veto state, or live-trial gate no longer matches.
  func prepareReflection(
    trigger: TriggerIdentity
  ) throws(StoreError) -> ReflectionPreparation?

  /// Takes the durable claim on one logical hypothesis, or returns nil when the key is not work
  /// this daemon may do: the job has moved to another epoch, the evidence is not something the
  /// evaluator may read, it already has a verdict, or another attempt at this key is live or
  /// already finished. A claim authorizes nothing — it only reserves the identity a later
  /// authorization can start.
  func claimOperation(
    _ key: LearningOperationKey,
    now: Date
  ) throws(StoreError) -> ClaimedOperation?

  /// Everything between the claim and the network, in one transaction. Checking the breakers
  /// outside the store and starting inside it lets two workers both read headroom and both
  /// dispatch. This re-reads the durable totals, verifies the job's epoch and the carrier
  /// authorization, records the reservation and the provider-call id, and compare-and-swaps
  /// `claimed → started`. Nothing may reach the network before it returns `.started`.
  func authorizeAndStartOperation(
    _ authorization: LearningAuthorization,
    now: Date
  ) throws(StoreError) -> AuthorizeOutcome

  /// Commits one network boundary crossing: the actual usage row under the reserved call id and
  /// the operation's terminal state, under the predicate `state == started`.
  ///
  /// - Returns: whether this call is the one that committed the result. `false` for a duplicate,
  ///   which writes nothing and cannot close the reservation a second time.
  func finishOperation(
    _ result: LearningOperationResult,
    now: Date
  ) throws(StoreError) -> Bool

  /// The frozen verdict on one run's evidence, written by the same transaction that committed the
  /// operation that produced it. Nil for a run nothing has evaluated.
  func evaluation(runId: Int64) throws(StoreError) -> LearningEvaluation?

  /// Reads one immutable reflector artifact back through its typed manifest. Admission consumes
  /// this row; it never invents a second candidate for the same reflection result.
  func candidateArtifact(digest: CandidateDigest) throws(StoreError) -> CandidateArtifact?

  /// The boot pass over what a prior process left open. A `started` operation may have reached the
  /// provider, so it is charged conservatively under its saved call id and closed as
  /// `interrupted_unknown` — never resent as the same inference. A `claimed` one provably never
  /// called, so it returns to `pending` and is claimable again.
  @discardableResult
  func reconcileOperationsAtBoot(now: Date) throws(StoreError) -> OperationReconciliation
}
