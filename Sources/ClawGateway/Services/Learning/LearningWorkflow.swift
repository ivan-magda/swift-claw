import ClawCore
import Foundation
import Logging

enum WorkflowStep: Hashable, Sendable {
  case reflection(TriggerDigest)
  case candidate(CandidateDigest)
  case control(Int64)
  case trial(Int64)
  case rollback(Int64)
}

/// An invocation's reviewed work identity; durable ownership belongs to the underlying transaction.
struct WorkflowClaim: Sendable {
  let step: WorkflowStep
}

/// Advances durable transitions to a wait state, using store CAS claims rather than process locks.
public struct LearningWorkflow: Sendable {
  static let maxTransitionsPerInvocation = 64
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

  public func advance(runID: Int64, now: Date) async {
    do {
      guard let binding = try store.binding(runID: runID) else {
        return
      }
      try store.sealEvidence(runID: runID, now: now)
      await runner.runEvaluation(runID: runID, now: now)
      guard !Task.isCancelled else {
        return
      }
      _ = try store.recomputeAssignment(runID: runID, now: now)
      await advance(jobID: binding.jobID, now: now)
    } catch {
      logger.error("run \(runID) learning workflow deferred: \(error)")
    }
  }

  public func advance(jobID: Int64, now: Date) async {
    await advance(jobID: jobID, now: now, transitionLimit: Self.maxTransitionsPerInvocation)
  }

  func advance(jobID: Int64, now: Date, transitionLimit: Int) async {
    do {
      guard try store.learningState(jobID: jobID) != nil else {
        return
      }
      var visited: Set<WorkflowStep> = []
      while let claim = try next(jobID: jobID, visited: visited, now: now) {
        guard !Task.isCancelled else {
          return
        }
        guard visited.count < transitionLimit else {
          logger.error("learning workflow hit its transition budget for job \(jobID)")
          return
        }
        visited.insert(claim.step)
        try await apply(claim, jobID: jobID, now: now)
      }
    } catch {
      logger.error("job \(jobID) learning workflow deferred: \(error)")
    }
  }
}

// MARK: - Fixed Point

private extension LearningWorkflow {
  func next(jobID: Int64, visited: Set<WorkflowStep>, now: Date) throws -> WorkflowClaim? {
    var steps: [WorkflowStep] = []
    steps += try store.workflowControls(jobID: jobID).map { control in
      .control(control.eventID)
    }
    if let trial = try store.openTrial(jobID: jobID) {
      steps.append(.trial(trial.trialID))
    }
    steps += try store.workflowRollbacks(jobID: jobID).map { trigger in
      switch trigger {
      case .ownerFeedback(_, let eventID), .supportWithdrawal(_, let eventID):
        return .rollback(eventID)
      case .adapter, .safety:
        return .rollback(trigger.promotionID)
      }
    }
    steps += try store.workflowCandidates(jobID: jobID).map(WorkflowStep.candidate)
    steps += try store.workflowTriggers(jobID: jobID, now: now).map { trigger in
      .reflection(trigger.digest)
    }
    return steps.first { step in
      !visited.contains(step)
    }.map(WorkflowClaim.init(step:))
  }

  func apply(_ claim: WorkflowClaim, jobID: Int64, now: Date) async throws {
    switch claim.step {
    case .reflection(let digest):
      if let trigger = try store.workflowTriggers(jobID: jobID, now: now).first(where: { trigger in
        trigger.digest == digest
      }) {
        await runner.runReflection(trigger: trigger, now: now)
      }
    case .candidate(let digest):
      let outcome = try store.admitCandidate(digest: digest, redactor: redactor, now: now)
      try notify(outcome, jobID: jobID, now: now)
    case .control(let eventID):
      try applyControl(eventID: eventID, jobID: jobID, now: now)
    case .trial:
      guard let trial = try store.openTrial(jobID: jobID),
            case .reconciled(let result) = try store.reconcileTrial(trial.identity, now: now),
            let current = try store.openTrial(jobID: jobID),
            let state = try store.learningState(jobID: jobID)
      else {
        return
      }
      _ = try store.applyTrialDecision(
        result.decision,
        trial: current,
        feedbackRevision: state.feedbackRevision,
        now: now
      )
    case .rollback(let eventID):
      for trigger in try store.workflowRollbacks(jobID: jobID) {
        switch trigger {
        case .ownerFeedback(_, let id) where id == eventID,
          .supportWithdrawal(_, let id) where id == eventID:
          _ = try store.rollback(trigger, now: now)
        default:
          break
        }
      }
    }
  }

  func applyControl(eventID: Int64, jobID: Int64, now: Date) throws {
    guard let control = try store.workflowControls(jobID: jobID).first(where: { control in
        control.eventID == eventID
      })
    else {
      return
    }

    let outcome: AdmissionOutcome
    switch control.signal {
    case .candidateApprove:
      outcome = try store.approveCandidate(
        CandidateApproval(predecessorDigest: control.candidate, feedbackEventID: control.eventID),
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
          feedbackEventID: control.eventID,
          payload: Data(payload.utf8)
        ),
        redactor: redactor,
        now: now
      )
    default:
      return
    }

    try notify(outcome, jobID: jobID, now: now)
  }

  func notify(_ outcome: AdmissionOutcome, jobID: Int64, now: Date) throws {
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
    guard let job = try jobs.job(id: jobID) else {
      return
    }
    _ = try notices.enqueueReview(
      candidate: candidate,
      state: state,
      ownerUserID: job.ownerChatID,
      chatID: job.ownerChatID,
      now: now
    )
  }
}
