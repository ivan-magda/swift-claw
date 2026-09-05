import ClawCore
import Foundation
import Logging

public enum WorkflowStep: Hashable, Sendable {
  case reflection(TriggerDigest)
  case candidate(CandidateDigest)
  case control(Int64)
  case trial(Int64)
  case rollback(Int64)
}

/// An invocation's reviewed work identity; durable ownership belongs to the underlying transaction.
public struct WorkflowClaim: Sendable {
  public let step: WorkflowStep
  public init(step: WorkflowStep) { self.step = step }
}

/// Advances durable transitions to a wait state, using store CAS claims rather than process locks.
public struct LearningWorkflow: Sendable {
  public static let maxTransitionsPerInvocation = 64
  let store: any LearningWorkflowStore
  private let jobs: any ScheduledJobStore
  private let runner: LearningOperationRunner
  private let notices: LearningNotices
  private let redactor: SecretRedactor
  private let logger: Logger

  public init(
    store: any LearningWorkflowStore,
    jobs: any ScheduledJobStore,
    runner: LearningOperationRunner,
    notices: LearningNotices,
    redactor: SecretRedactor,
    logger: Logger
  ) {
    self.store = store
    self.jobs = jobs
    self.runner = runner
    self.notices = notices
    self.redactor = redactor
    self.logger = logger
  }

  public func advance(runId: Int64, now: Date) async {
    do {
      guard let binding = try store.binding(runId: runId) else {
        return
      }
      try store.sealEvidence(runId: runId, now: now)
      await runner.runEvaluation(runId: runId, now: now)
      guard !Task.isCancelled else {
        return
      }
      _ = try store.recomputeAssignment(runId: runId, now: now)
      await advance(jobId: binding.jobId, now: now)
    } catch {
      logger.error("run \(runId) learning workflow deferred: \(error)")
    }
  }

  public func advance(jobId: Int64, now: Date) async {
    do {
      guard try store.learningState(jobId: jobId) != nil else {
        return
      }
      var visited: Set<WorkflowStep> = []
      while let claim = try next(jobId: jobId, visited: visited, now: now) {
        guard !Task.isCancelled else {
          return
        }
        guard visited.count < Self.maxTransitionsPerInvocation else {
          logger.error("learning workflow hit its transition budget for job \(jobId)")
          return
        }
        visited.insert(claim.step)
        try await apply(claim, jobId: jobId, now: now)
      }
    } catch {
      logger.error("job \(jobId) learning workflow deferred: \(error)")
    }
  }
}

// MARK: - Fixed Point

private extension LearningWorkflow {
  func next(jobId: Int64, visited: Set<WorkflowStep>, now: Date) throws -> WorkflowClaim? {
    var steps: [WorkflowStep] = []
    steps += try store.workflowControls(jobId: jobId).map { control in
      .control(control.eventId)
    }
    if let trial = try store.openTrial(jobId: jobId) {
      steps.append(.trial(trial.trialId))
    }
    steps += try store.workflowRollbacks(jobId: jobId).map { trigger in
      switch trigger {
      case .ownerFeedback(_, let eventId), .supportWithdrawal(_, let eventId):
        return .rollback(eventId)
      case .adapter, .safety:
        return .rollback(trigger.promotionId)
      }
    }
    steps += try store.workflowCandidates(jobId: jobId).map(WorkflowStep.candidate)
    steps += try store.workflowTriggers(jobId: jobId, now: now).map { trigger in
      .reflection(trigger.digest)
    }
    return steps.first(where: { step in
      !visited.contains(step)
    }).map(WorkflowClaim.init(step:))
  }

  func apply(_ claim: WorkflowClaim, jobId: Int64, now: Date) async throws {
    switch claim.step {
    case .reflection(let digest):
      if let trigger = try store.workflowTriggers(jobId: jobId, now: now)
        .first(where: { trigger in
          trigger.digest == digest
        })
      {
        await runner.runReflection(trigger: trigger, now: now)
      }
    case .candidate(let digest):
      let outcome = try store.admitCandidate(digest: digest, redactor: redactor, now: now)
      try notify(outcome, jobId: jobId, now: now)
    case .control(let eventId):
      guard
        let control = try store.workflowControls(jobId: jobId)
          .first(where: { control in
            control.eventId == eventId
          })
      else {
        return
      }
      let outcome: AdmissionOutcome
      switch control.signal {
      case .candidateApprove:
        outcome = try store.approveCandidate(
          CandidateApproval(
            predecessorDigest: control.candidate,
            feedbackEventId: control.eventId
          ),
          redactor: redactor,
          now: now
        )
      case .candidateEdit:
        guard let payload = control.payload else {
          return
        }
        outcome = try store.editCandidate(
          CandidateEdit(
            predecessorDigest: control.candidate,
            feedbackEventId: control.eventId,
            payload: Data(payload.utf8)
          ),
          redactor: redactor,
          now: now
        )
      default:
        return
      }
      try notify(outcome, jobId: jobId, now: now)
    case .trial:
      guard let trial = try store.openTrial(jobId: jobId),
        case .reconciled(let result) = try store.reconcileTrial(trial.identity, now: now),
        let current = try store.openTrial(jobId: jobId),
        let state = try store.learningState(jobId: jobId)
      else {
        return
      }
      _ = try store.applyTrialDecision(
        result.decision,
        trial: current,
        feedbackRevision: state.feedbackRevision,
        now: now
      )
    case .rollback(let eventId):
      for trigger in try store.workflowRollbacks(jobId: jobId) {
        switch trigger {
        case .ownerFeedback(_, let id) where id == eventId,
          .supportWithdrawal(_, let id) where id == eventId:
          _ = try store.rollback(trigger, now: now)
        default:
          break
        }
      }
    }
  }

  func notify(_ outcome: AdmissionOutcome, jobId: Int64, now: Date) throws {
    let candidate: CandidateArtifact
    let state: CandidateReviewState
    switch outcome {
    case .admitted(let receipt):
      guard let artifact = try store.candidateArtifact(digest: receipt.candidateDigest) else {
        return
      }
      candidate = artifact
      state = .admitted
    case .awaitingApproval(let artifact):
      candidate = artifact
      state = .awaitingApproval
    case .rejected:
      return
    }
    guard let job = try jobs.job(id: jobId) else {
      return
    }
    _ = try notices.enqueueReview(
      candidate: candidate,
      state: state,
      ownerUserId: job.ownerChatId,
      chatId: job.ownerChatId,
      now: now
    )
  }
}
