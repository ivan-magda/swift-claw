import Foundation

/// One authenticated owner-feedback fact after its storage seam has bound it to an exact subject.
/// Persistence owns authentication and nonce validation; this value is the pure reducer's input.
public struct FeedbackEvent: Sendable, Equatable {
  public let id: Int64
  public let runId: Int64?
  public let signal: OwnerSignal
  public let payload: String?
  public let revision: FeedbackRevision
  public let supersedes: Int64?
  public let occurredAt: Date
  public let actor: AuditActor
  public let transportUpdateId: Int64?

  public init(
    id: Int64,
    runId: Int64?,
    signal: OwnerSignal,
    payload: String?,
    revision: FeedbackRevision,
    supersedes: Int64?,
    occurredAt: Date,
    actor: AuditActor = .owner,
    transportUpdateId: Int64? = nil
  ) {
    self.id = id
    self.runId = runId
    self.signal = signal
    self.payload = payload
    self.revision = revision
    self.supersedes = supersedes
    self.occurredAt = occurredAt
    self.actor = actor
    self.transportUpdateId = transportUpdateId
  }
}

/// The four independent veto classes that stop a decision even when its quality evidence is
/// positive. Callers bind each value to the exact dependency or execution surface it governs.
public enum HardVeto: Sendable, Hashable, CaseIterable {
  case ownerDependencyRejected
  case criticalOrRegressionReceipt
  case securityOrIntegrityReceipt
  case staleControlState
}

/// The one effective quality outcome and the independent claims that constrain its use.
public struct ResolvedOutcome: Sendable, Equatable {
  public let outcome: EffectiveOutcome
  public let ownerConfirmed: Bool
  public let hardVetoes: Set<HardVeto>

  public init(
    outcome: EffectiveOutcome,
    ownerConfirmed: Bool,
    hardVetoes: Set<HardVeto>
  ) {
    self.outcome = outcome
    self.ownerConfirmed = ownerConfirmed
    self.hardVetoes = hardVetoes
  }

  public var permitsDependentDecision: Bool {
    hardVetoes.isEmpty
  }
}

public enum OwnerPrecedence {
  public static let syntheticNotUsefulCode = "owner_not_useful"

  /// Resolves one exact run at a frozen feedback revision. `signals` are already authenticated and
  /// subject-bound by the persistence boundary.
  public static func resolve(
    evaluator: EvaluatorOutcome?,
    issueCodes: [String],
    signals: [FeedbackEvent],
    hardVetoes: Set<HardVeto> = []
  ) -> ResolvedOutcome {
    let effectiveSignals = FeedbackEvent.unsuperseded(signals)
    let resultSignal = FeedbackEvent.latestUnsupersededResult(in: signals)
    let evaluationDisputed = effectiveSignals.contains { event in
      event.signal == .evaluationDispute
    }
    var effectiveVetoes = hardVetoes
    if evaluationDisputed {
      effectiveVetoes.insert(.ownerDependencyRejected)
    }

    let outcome =
      resultSignal.map { event in
        Self.ownerOutcome(signal: event.signal, evaluatorIssueCodes: issueCodes)
      }
      ?? Self.evaluatorOutcome(
        evaluator,
        issueCodes: issueCodes,
        isDisputed: evaluationDisputed
      )
    let ownerConfirmed =
      resultSignal == nil && evaluationDisputed == false
      && effectiveSignals.contains { event in
        event.signal == .evaluationConfirm
      }
    return ResolvedOutcome(
      outcome: outcome,
      ownerConfirmed: ownerConfirmed,
      hardVetoes: effectiveVetoes
    )
  }
}

// MARK: - Resolution

private extension OwnerPrecedence {
  static func ownerOutcome(
    signal: OwnerSignal,
    evaluatorIssueCodes: [String]
  ) -> EffectiveOutcome {
    switch signal {
    case .resultUseful:
      return .positive
    case .resultNotUseful:
      let codes =
        evaluatorIssueCodes.isEmpty
        ? [syntheticNotUsefulCode]
        : evaluatorIssueCodes.sorted()
      return .negative(issueCodes: codes)
    case .resultCorrection:
      return .negative(issueCodes: evaluatorIssueCodes.sorted())
    case .evaluationConfirm, .evaluationDispute, .candidateApprove, .candidateReject,
      .candidateEdit, .promotionRollback:
      return .neutral
    }
  }

  static func evaluatorOutcome(
    _ evaluator: EvaluatorOutcome?,
    issueCodes: [String],
    isDisputed: Bool
  ) -> EffectiveOutcome {
    guard isDisputed == false else {
      return .neutral
    }
    switch evaluator {
    case .noIssue:
      return .positive
    case .reusableIssue:
      return .negative(issueCodes: issueCodes.sorted())
    case .transientIssue, .uncertain, nil:
      return .neutral
    }
  }
}

// MARK: - Supersession

extension FeedbackEvent {
  static func latestUnsupersededResult(in events: [FeedbackEvent]) -> FeedbackEvent? {
    unsuperseded(events)
      .filter { event in
        event.signal.isResultSignal
      }
      .max(by: precedes)
  }

  static func unsuperseded(_ events: [FeedbackEvent]) -> [FeedbackEvent] {
    let superseded = Set(events.compactMap(\.supersedes))
    return events.filter { event in
      superseded.contains(event.id) == false
    }
  }

  private static func precedes(_ lhs: FeedbackEvent, _ rhs: FeedbackEvent) -> Bool {
    if lhs.revision != rhs.revision {
      return lhs.revision < rhs.revision
    }
    if lhs.occurredAt != rhs.occurredAt {
      return lhs.occurredAt < rhs.occurredAt
    }
    return lhs.id < rhs.id
  }
}

private extension OwnerSignal {
  var isResultSignal: Bool {
    switch self {
    case .resultUseful, .resultNotUseful, .resultCorrection:
      true
    case .evaluationConfirm, .evaluationDispute, .candidateApprove, .candidateReject,
      .candidateEdit, .promotionRollback:
      false
    }
  }
}
