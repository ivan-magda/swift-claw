import ClawCore
import Foundation

/// Prepares optional durable sources. Archive text stays unbounded until secrets are removed.
public struct JournalSourceCapture: Sendable {
  let policy: JournalPolicy
  let redact: @Sendable (String) -> String

  public init(policy: JournalPolicy, redact: @escaping @Sendable (String) -> String) {
    self.policy = policy
    self.redact = redact
  }

  public func scope(userID: Int64, chatID: Int64, mode: ChatMode) -> JournalScope? {
    guard mode == .direct, let scope = policy.scope,
          userID == scope.ownerUserID, chatID == scope.ownerUserID
    else {
      return nil
    }
    return scope
  }

  public func admission(message: IncomingMessage, mode: ChatMode) -> JournalExchangeAdmission? {
    guard let scope = scope(userID: message.userID, chatID: message.chatID, mode: mode),
          let sourceTimestamp = message.sourceTimestamp,
          let timeZone = TimeZone(identifier: scope.timeZoneID)
    else {
      return nil
    }
    return JournalExchangeAdmission(
      scope: scope,
      sourceTimestamp: sourceTimestamp,
      sourceDay: JournalDay.containing(sourceTimestamp, timeZone: timeZone)
    )
  }

  public func exchange(
    input: JournalExchangeInput,
    reply: String,
    evidence: [JournalEvidence]
  ) -> JournalSource? {
    guard policy.scope?.ownerUserID == input.admission.scope.ownerUserID else {
      return nil
    }
    let proposal = input.supportingProposal.flatMap { proposal in
      try? JournalProposal(
        sourceID: proposal.sourceID,
        text: bounded(proposal.text, limit: JournalLimits.proposalGraphemes)
      )
    }
    return try? JournalSource(
      id: "message:\(input.triggerMessageID)",
      scope: input.admission.scope,
      sessionID: input.sessionID,
      occurredAt: input.admission.sourceTimestamp,
      day: input.admission.sourceDay,
      ownerText: bounded(input.ownerText, limit: JournalLimits.ownerTextGraphemes),
      assistantText: bounded(reply, limit: JournalLimits.assistantTextGraphemes),
      supportingProposal: proposal,
      evidence: evidence.prefix(JournalLimits.evidenceEntries).compactMap(redactedEvidence)
    )
  }

  public func coder(job: CoderJob, result: CoderResult, completedAt: Date) -> JournalSource? {
    guard let scope = job.journalScope, policy.scope?.ownerUserID == scope.ownerUserID,
          job.origin.requesterUserID == scope.ownerUserID, job.origin.chatID == scope.ownerUserID,
          result.state.isTerminal, let timeZone = TimeZone(identifier: scope.timeZoneID)
    else {
      return nil
    }
    var evidence = [
      try? JournalEvidence(
        outcome: .coder(result.state),
        jobID: job.id,
        name: "Coder terminal state"
      ),
      try? JournalEvidence(
        outcome: .publication(redactedPublication(result.publication)),
        jobID: job.id,
        name: "Coder publication"
      ),
    ].compactMap { $0 }
    for check in result.reportedChecks.prefix(JournalLimits.evidenceEntries - evidence.count) {
      if let entry = try? JournalEvidence(
        outcome: .workerReportedChecks,
        jobID: job.id,
        name: "Worker-reported check",
        detail: bounded(check, limit: JournalLimits.evidenceFieldGraphemes)
      ) {
        evidence.append(entry)
      }
    }
    let task = [
      job.prepared.request.task ?? job.prepared.canonicalSource,
      job.prepared.request.instructions,
    ].compactMap { $0 }.joined(separator: "\n")
    return try? JournalSource(
      id: "coder:\(job.id.uuidString)",
      scope: scope,
      sessionID: job.origin.sessionID,
      occurredAt: completedAt,
      day: JournalDay.containing(completedAt, timeZone: timeZone),
      ownerText: bounded(task, limit: JournalLimits.ownerTextGraphemes),
      assistantText: bounded(result.summary, limit: JournalLimits.assistantTextGraphemes),
      coderJobID: job.id,
      evidence: evidence
    )
  }

  func toolEvidence(exchanges: [ToolExchange]) -> [JournalEvidence] {
    exchanges.flatMap(\.observations).prefix(JournalLimits.evidenceEntries).compactMap {
      observation in
      // Persisted prose is not proof of an operation. Only the dispatcher-owned status is evidence.
      try? JournalEvidence(
        outcome: .tool(observation.status),
        name: bounded(observation.toolName, limit: JournalLimits.evidenceFieldGraphemes)
      )
    }
  }
}

// MARK: - Redacted Bounds

private extension JournalSourceCapture {
  func bounded(_ text: String, limit: Int) -> String {
    let redacted = redact(text)
    guard redacted.count > limit else {
      return redacted
    }
    let marker = "\n[…]\n"
    let available = limit - marker.count
    let head = available / 3
    return String(redacted.prefix(head)) + marker + String(redacted.suffix(available - head))
  }

  func redactedPublication(_ publication: CoderPublication) -> CoderPublication {
    switch publication {
    case .absent:
      .absent
    case .confirmed(let url):
      .confirmed(url: bounded(url, limit: JournalLimits.evidenceFieldGraphemes))
    case .unknown(let reportedURL):
      .unknown(
        reportedURL: reportedURL.map {
          bounded($0, limit: JournalLimits.evidenceFieldGraphemes)
        }
      )
    }
  }

  func redactedEvidence(_ evidence: JournalEvidence) -> JournalEvidence? {
    let outcome: JournalEvidence.Outcome =
      if case .publication(let publication) = evidence.outcome {
        .publication(redactedPublication(publication))
      } else {
        evidence.outcome
      }
    return try? JournalEvidence(
      outcome: outcome,
      jobID: evidence.jobID,
      name: bounded(evidence.name, limit: JournalLimits.evidenceFieldGraphemes),
      detail: evidence.detail.map { bounded($0, limit: JournalLimits.evidenceFieldGraphemes) }
    )
  }
}
