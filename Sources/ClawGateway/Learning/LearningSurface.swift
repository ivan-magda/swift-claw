import ClawCore
import Foundation

/// Pure owner-facing rendering for the typed learning snapshot.
public enum LearningSurface {
  public static let emptyList = "No scheduled jobs have learning state yet."

  public enum Style: Sendable {
    case list
    case detail
  }

  public static func render(_ views: [JobLearningView], style: Style = .detail) -> String {
    switch style {
    case .list:
      return renderList(views)
    case .detail:
      return renderDetail(views)
    }
  }
}

// MARK: - List

private extension LearningSurface {
  static func renderList(_ views: [JobLearningView]) -> String {
    guard views.isEmpty == false else {
      return emptyList
    }
    return views.map(listLine).joined(separator: "\n")
  }

  static func listLine(_ view: JobLearningView) -> String {
    switch view {
    case .readable(let readable):
      let trial =
        readable.liveTrial.map { value in
          "trial \(value.state.rawValue) \(value.counts.consumed)/\(value.counts.maximum)"
            + " (\(value.counts.unresolved) unresolved)"
        } ?? "no live trial"
      let decision =
        readable.lastDecision.map { value in
          "last \(decisionKind(value.detail)) \(value.decidedAt.wallClockMinute(in: zone(readable)))"
        } ?? "no decision"
      let warning = readable.warnings.isEmpty ? "" : " · warning"
      return """
        \(readable.job.jobId) · \(readable.job.label) · \(readable.job.status.rawValue) · \
        epoch \(readable.epoch.value) · \(readable.stableLessons.lessons.count) lessons · \
        \(trial) · \(decision)\(warning)
        """
    case .unreadable(let job):
      return "\(job.jobId) · \(job.validatedLabel ?? "unknown label") · learning state unreadable"
    case .unarmed(let job):
      return "\(job.jobId) · \(job.label) · no learning state"
    case .notFound(let jobId):
      return "No schedule with id \(jobId). See /schedule list."
    }
  }
}

// MARK: - Detail

private extension LearningSurface {
  static func renderDetail(_ views: [JobLearningView]) -> String {
    guard views.isEmpty == false else {
      return emptyList
    }
    return views.map(detail).joined(separator: "\n\n")
  }

  static func detail(_ view: JobLearningView) -> String {
    switch view {
    case .notFound(let jobId):
      return "No schedule with id \(jobId). See /schedule list."
    case .unarmed(let job):
      return """
        Schedule \(job.jobId) · \(job.label)
        status: \(job.status.rawValue)
        timezone: \(job.timezone)
        learning state: not created
        """
    case .unreadable(let job):
      return """
        Schedule \(job.jobId) · \(job.validatedLabel ?? "unknown label")
        learning state: unreadable
        Run /doctor and inspect the daemon logs; this read did not change or repair stored state.
        """
    case .readable(let readable):
      return readableDetail(readable)
    }
  }

  static func readableDetail(_ view: ReadableJobLearningView) -> String {
    var lines = [
      "Schedule \(view.job.jobId) · \(view.job.label)",
      "status: \(view.job.status.rawValue)",
      "timezone: \(view.job.timezone)",
      "learning epoch: \(view.epoch.value)",
      "stable revision: \(view.stableRevision.value)",
      "stable digest: \(view.stableLessons.digest.rawValue)",
      "lessons (\(view.stableLessons.lessons.count)):",
    ]
    if view.stableLessons.lessons.isEmpty {
      lines.append("  none")
    } else {
      for (index, lesson) in view.stableLessons.lessons.enumerated() {
        lines.append("  \(index + 1). \(lesson)")
      }
    }
    lines.append(contentsOf: trialLines(view.liveTrial, timezone: zone(view)))
    lines.append(contentsOf: decisionLines(view.lastDecision, timezone: zone(view)))
    for warning in view.warnings {
      lines.append("warning: \(warningText(warning))")
    }
    return lines.joined(separator: "\n")
  }

  static func trialLines(_ trial: LearningTrialView?, timezone: TimeZone) -> [String] {
    guard let trial else {
      return ["live trial: none"]
    }
    return [
      "live trial: \(trial.trialId)",
      "trial epoch: \(trial.epoch.value)",
      "trial generation: \(trial.generation)",
      "trial state: \(trial.state.rawValue)",
      "candidate digest: \(trial.candidateDigest.rawValue)",
      "trial base digest: \(trial.baseDigest.rawValue)",
      "trial base revision: \(trial.baseRevision.value)",
      "replacement digest: \(trial.replacementDigest.rawValue)",
      "assignments: \(trial.counts.consumed) of \(trial.counts.maximum)",
      "assignment outcomes: \(trial.counts.unresolved) unresolved",
      "assignment deadline: \(time(trial.assignmentDeadline, timezone: timezone))",
      "decision deadline: \(time(trial.decisionDeadline, timezone: timezone))",
    ]
  }

  static func decisionLines(
    _ decision: LearningDecisionView?,
    timezone: TimeZone
  ) -> [String] {
    guard let decision else {
      return ["last decision: none"]
    }
    var lines = [
      "last decision: \(decision.decisionId)",
      "decision kind: \(decisionKind(decision.detail))",
      "decision job: \(decision.jobId)",
      "decision epoch: \(decision.epoch.value)",
      "decision algorithm: \(decision.algorithm.rawValue)",
      "decided at: \(time(decision.decidedAt, timezone: timezone))",
    ]
    switch decision.detail {
    case .candidateAdmission(let inputs, let result):
      lines.append("decision input candidate: \(inputs.candidateDigest.rawValue)")
      lines.append("decision result candidate: \(result.candidateDigest.rawValue)")
      lines.append("decision result replacement: \(result.replacementDigest.rawValue)")
      lines.append("decision result trial: \(result.trialId)")
      lines.append("decision result generation: \(result.generation)")
    case .reflectionNoCandidate(let inputs, let result):
      lines.append("decision input trigger: \(inputs.triggerDigest.rawValue)")
      lines.append("decision input operation: \(inputs.operationId.rawValue)")
      lines.append("decision input carrier: \(inputs.carrierDigest.rawValue)")
      lines.append("decision result digest: \(result.resultDigest.rawValue)")
    case .learningReset(let inputs, let result):
      lines.append("reset old epoch: \(inputs.oldEpoch.value)")
      lines.append("reset new epoch: \(result.newEpoch.value)")
      lines.append("reset old stable digest: \(inputs.oldStableDigest.rawValue)")
      lines.append("reset empty stable digest: \(result.emptyStableDigest.rawValue)")
      lines.append("reset old stable revision: \(inputs.oldStableRevision.value)")
      lines.append("reset new stable revision: \(result.newStableRevision.value)")
      lines.append("reset feedback revision: \(inputs.feedbackRevisionAtCut.value)")
      lines.append("reset prior live trial: \(inputs.priorOpenTrialId.map(String.init) ?? "none")")
      lines.append("reset closed trials: \(result.closedTrials.count)")
      lines.append("reset invalidated targets: \(result.invalidatedTargetCount)")
      lines.append("reset invalidated challenges: \(result.invalidatedChallengeCount)")
      lines.append("reset abandoned calls: \(result.staleNoCallOperationIds.count)")
      lines.append("reset in-flight calls: \(result.inFlightOperationIds.count)")
    }
    return lines
  }

  static func decisionKind(_ detail: LearningDecisionDetail) -> String {
    switch detail {
    case .candidateAdmission:
      AdmissionReceipt.kind
    case .reflectionNoCandidate:
      ReflectionNoCandidateReceipt.kind
    case .learningReset:
      ResetReceipt.kind
    }
  }

  static func warningText(_ warning: LearningViewWarning) -> String {
    switch warning {
    case .trialPointerMismatch:
      "stored trial pointer does not match the live trial"
    }
  }

  static func zone(_ view: ReadableJobLearningView) -> TimeZone {
    TimeZone(identifier: view.job.timezone) ?? .gmt
  }

  static func time(_ date: Date, timezone: TimeZone) -> String {
    "\(date.wallClockMinute(in: timezone)) (\(timezone.identifier))"
  }
}
