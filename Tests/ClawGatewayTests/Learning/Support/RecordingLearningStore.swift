import ClawCore
import Foundation

@testable import ClawData

// MARK: - Authorization Decorator

/// The real store with its authorization hop observed, and optionally answered. Everything else
/// stays the real row, so the operation the runner claimed is genuinely there to inspect.
///
/// Lock-guarded, not an actor: `ScheduledLearningStore` is synchronous — the GRDB stores are
/// `Sendable` wrappers that lean on GRDB's own serialization — and an actor cannot satisfy a
/// synchronous requirement.
final class RecordingLearningStore: ScheduledLearningStore, @unchecked Sendable {
  func sweepRetention(now: Date) throws(StoreError) -> RetentionSweepResult {
    try base.sweepRetention(now: now)
  }

  struct ServiceBehavior: Sendable {
    let identities: [LearningTrialIdentity]?
    let trialResults: [Int64: TrialReconciliationResult]
    let failingTrialIds: Set<Int64>
    let failEnumeration: Bool
    let unsealedRunIds: [Int64]?
    let handledSealRunIds: Set<Int64>

    init(
      identities: [LearningTrialIdentity]? = nil,
      trialResults: [Int64: TrialReconciliationResult] = [:],
      failingTrialIds: Set<Int64> = [],
      failEnumeration: Bool = false,
      unsealedRunIds: [Int64]? = nil,
      handledSealRunIds: Set<Int64> = []
    ) {
      self.identities = identities
      self.trialResults = trialResults
      self.failingTrialIds = failingTrialIds
      self.failEnumeration = failEnumeration
      self.unsealedRunIds = unsealedRunIds
      self.handledSealRunIds = handledSealRunIds
    }
  }

  private let lock = NSLock()
  private let base: ScheduledLearningStoreGRDB
  private let supersedes: Bool
  private let admissionFails: Bool
  private let recordsReviewCommits: Bool
  private let failingReviewCandidate: CandidateDigest?
  private let serviceBehavior: ServiceBehavior
  private let onUnsealed: @Sendable () -> Void
  private var presented: [LearningAuthorization] = []
  private var reviewSubjects: Set<String> = []
  private var admissions = 0
  private var recordedServiceCalls: [String] = []
  private var bootReconciliationFails = false

  init(
    base: ScheduledLearningStoreGRDB,
    supersedes: Bool = false,
    admissionFails: Bool = false,
    recordsReviewCommits: Bool = false,
    failingReviewCandidate: CandidateDigest? = nil,
    serviceBehavior: ServiceBehavior = ServiceBehavior(),
    onUnsealed: @escaping @Sendable () -> Void = {}
  ) {
    self.base = base
    self.supersedes = supersedes
    self.admissionFails = admissionFails
    self.recordsReviewCommits = recordsReviewCommits
    self.failingReviewCandidate = failingReviewCandidate
    self.serviceBehavior = serviceBehavior
    self.onUnsealed = onUnsealed
  }

  /// Every authorization the runner presented, in order.
  var authorizations: [LearningAuthorization] {
    lock.lock()
    defer { lock.unlock() }
    return presented
  }

  var admissionAttempts: Int {
    lock.withLock { admissions }
  }

  var serviceCalls: [String] {
    lock.withLock { recordedServiceCalls }
  }

  var failBootReconciliation: Bool {
    get { lock.withLock { bootReconciliationFails } }
    set { lock.withLock { bootReconciliationFails = newValue } }
  }

  func clearServiceCalls() {
    lock.withLock { recordedServiceCalls.removeAll() }
  }

  func applyTrialDecision(
    _ decision: TrialDecision,
    trial: LearningTrial,
    feedbackRevision: FeedbackRevision,
    now: Date
  ) throws(StoreError) -> DecisionReceipt? {
    try base.applyTrialDecision(
      decision,
      trial: trial,
      feedbackRevision: feedbackRevision,
      now: now
    )
  }

  func rollback(_ trigger: RollbackTrigger, now: Date) throws(StoreError) -> DecisionReceipt? {
    try base.rollback(trigger, now: now)
  }

  func commitPromotionReply(
    updateId: Int64,
    target: NewFeedbackTarget,
    chunks: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) -> PromotionReplyOutcome {
    try base.commitPromotionReply(updateId: updateId, target: target, chunks: chunks, now: now)
  }

  func currentPromotion(jobId: Int64) throws(StoreError) -> DecisionReceipt? {
    try base.currentPromotion(jobId: jobId)
  }

  func learningView(jobId: Int64?) throws(StoreError) -> [JobLearningView] {
    try base.learningView(jobId: jobId)
  }

  func applyReset(
    updateId: Int64,
    jobId: Int64,
    now: Date
  ) throws(StoreError) -> ConfirmedLearningResetResult {
    try base.applyReset(updateId: updateId, jobId: jobId, now: now)
  }

  func createTargets(
    _ targets: [NewFeedbackTarget],
    chunks: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) {
    try base.createTargets(targets, chunks: chunks, now: now)
  }

  func feedbackTarget(nonce: String) throws(StoreError) -> FeedbackTarget? {
    try base.feedbackTarget(nonce: nonce)
  }

  func consumeAndAppendEvent(
    _ tap: FeedbackTap,
    now: Date
  ) throws(StoreError) -> FeedbackOutcome {
    try base.consumeAndAppendEvent(tap, now: now)
  }

  func consumeAndOpenChallenge(
    _ tap: FeedbackTap,
    prompt: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) -> FeedbackOutcome {
    try base.consumeAndOpenChallenge(tap, prompt: prompt, now: now)
  }

  func consumeChallenge(
    id: Int64,
    payload: String,
    now: Date
  ) throws(StoreError) -> FeedbackOutcome {
    try base.consumeChallenge(id: id, payload: payload, now: now)
  }

  func liveChallenge(
    ownerUserId: Int64,
    chatId: Int64
  ) throws(StoreError) -> FeedbackChallenge? {
    try base.liveChallenge(ownerUserId: ownerUserId, chatId: chatId)
  }

  func admitCandidate(
    digest: CandidateDigest,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome {
    lock.withLock { admissions += 1 }
    guard admissionFails == false else {
      throw .unexpected("injected admission failure")
    }
    return try base.admitCandidate(digest: digest, redactor: redactor, now: now)
  }

  func approveCandidate(
    _ approval: CandidateApproval,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome {
    try base.approveCandidate(approval, redactor: redactor, now: now)
  }

  func editCandidate(
    _ edit: CandidateEdit,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome {
    try base.editCandidate(edit, redactor: redactor, now: now)
  }

  func commitCandidateReview(
    _ review: CandidateReviewNotice,
    now: Date
  ) throws(StoreError) -> Bool {
    if review.candidateDigest == failingReviewCandidate {
      throw .unexpected("injected review failure")
    }
    if recordsReviewCommits {
      lock.lock()
      let inserted = reviewSubjects.insert(review.subjectDigest).inserted
      lock.unlock()
      return inserted
    }
    return try base.commitCandidateReview(review, now: now)
  }

  func authorizeAndStartOperation(
    _ authorization: LearningAuthorization,
    now: Date
  ) throws(StoreError) -> AuthorizeOutcome {
    lock.lock()
    presented.append(authorization)
    lock.unlock()
    guard supersedes == false else {
      return .superseded
    }
    return try base.authorizeAndStartOperation(authorization, now: now)
  }

  func armJob(jobId: Int64, now: Date) throws(StoreError) -> JobLearningState {
    try base.armJob(jobId: jobId, now: now)
  }

  func lessonSet(jobId: Int64, digest: LessonSetDigest) throws(StoreError) -> LessonSet? {
    try base.lessonSet(jobId: jobId, digest: digest)
  }

  func binding(runId: Int64) throws(StoreError) -> RunLearningBinding? {
    try base.binding(runId: runId)
  }

  func openTrial(jobId: Int64) throws(StoreError) -> LearningTrial? {
    try base.openTrial(jobId: jobId)
  }

  func recomputeAssignment(
    runId: Int64,
    now: Date
  ) throws(StoreError) -> AssignmentRecomputation {
    try base.recomputeAssignment(runId: runId, now: now)
  }

  func liveTrialIdentities() throws(StoreError) -> [LearningTrialIdentity] {
    recordServiceCall("live")
    if serviceBehavior.failEnumeration {
      throw .unexpected("injected live-trial enumeration failure")
    }
    if let identities = serviceBehavior.identities {
      return identities
    }
    return try base.liveTrialIdentities()
  }

  func reconcileTrial(
    _ identity: LearningTrialIdentity,
    now: Date
  ) throws(StoreError) -> TrialReconciliationResult {
    recordServiceCall("trial:\(identity.trialId)")
    if serviceBehavior.failingTrialIds.contains(identity.trialId) {
      throw .unexpected("injected trial reconciliation failure")
    }
    if let result = serviceBehavior.trialResults[identity.trialId] {
      return result
    }
    return try base.reconcileTrial(identity, now: now)
  }

  func settlement(runId: Int64) throws(StoreError) -> RunSettlement? {
    try base.settlement(runId: runId)
  }

  @discardableResult
  func settleFromLane(runId: Int64, now: Date) throws(StoreError) -> Bool {
    try base.settleFromLane(runId: runId, now: now)
  }

  func freezeCompatibility(runId: Int64, surface: RunSurface) throws(StoreError) {
    try base.freezeCompatibility(runId: runId, surface: surface)
  }

  func compatibility(runId: Int64) throws(StoreError) -> RunCompatibility? {
    try base.compatibility(runId: runId)
  }

  func unsealed(limit: Int) throws(StoreError) -> [Int64] {
    onUnsealed()
    recordServiceCall("unsealed")
    if let runIds = serviceBehavior.unsealedRunIds {
      return runIds
    }
    return try base.unsealed(limit: limit)
  }

  @discardableResult
  func sealEvidence(runId: Int64, now: Date) throws(StoreError) -> SealOutcome {
    recordServiceCall("seal:\(runId)")
    if serviceBehavior.handledSealRunIds.contains(runId) {
      return .alreadySealed
    }
    return try base.sealEvidence(runId: runId, now: now)
  }

  func evidence(runId: Int64) throws(StoreError) -> SealedEvidence? {
    try base.evidence(runId: runId)
  }

  func prepareReflection(
    trigger: TriggerIdentity
  ) throws(StoreError) -> ReflectionPreparation? {
    try base.prepareReflection(trigger: trigger)
  }

  func claimOperation(
    _ key: LearningOperationKey,
    now: Date
  ) throws(StoreError) -> ClaimedOperation? {
    try base.claimOperation(key, now: now)
  }

  func finishOperation(
    _ result: LearningOperationResult,
    now: Date
  ) throws(StoreError) -> Bool {
    try base.finishOperation(result, now: now)
  }

  func evaluation(runId: Int64) throws(StoreError) -> LearningEvaluation? {
    try base.evaluation(runId: runId)
  }

  func candidateArtifact(digest: CandidateDigest) throws(StoreError) -> CandidateArtifact? {
    try base.candidateArtifact(digest: digest)
  }

  @discardableResult
  func reconcileOperationsAtBoot(now: Date) throws(StoreError) -> OperationReconciliation {
    recordServiceCall("operations")
    if failBootReconciliation {
      throw .unexpected("injected operation reconciliation failure")
    }
    return try base.reconcileOperationsAtBoot(now: now)
  }
}

private extension RecordingLearningStore {
  func recordServiceCall(_ call: String) {
    lock.withLock { recordedServiceCalls.append(call) }
  }
}
