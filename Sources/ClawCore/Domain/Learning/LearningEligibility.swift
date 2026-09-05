import Foundation

public extension LearningEligibility {
  /// The one gate in front of learning model spend. Every other value is a terminal classification
  /// the loop records and stops on, so this stays a single equality rather than a list that could
  /// drift open.
  var reachesEvaluator: Bool {
    self == .eligibleTaskEvidence
  }
}

/// The deterministic map from a settled run's terminal cause and transcript shape onto the evidence
/// taxonomy. Pure — no I/O, no clock, no model call — because it runs before any learning spend and
/// its verdict is terminal: no later worker reinterprets an ineligible receipt.
public enum EligibilityClassifier {
  /// Stamped on every eligibility receipt. A change to the rules below must open a new
  /// compatibility window rather than silently reinterpret the receipts an earlier version wrote.
  public static let version = "eligibility/v1"

  public static func classify(
    _ settlement: RunSettlement,
    transcript: EvidenceTranscript
  ) -> LearningEligibility {
    // Transcript first. A run whose evidence cannot be reconstructed whole is neutral however it
    // ended: the evaluator must never receive a partial reconstruction, and a truncated answer
    // would read as the model's own.
    guard transcript.isReconstructable else {
      return .insufficientEvidence
    }
    return classify(settlement.terminalCause)
  }
}

// MARK: - Terminal Cause Mapping

private extension EligibilityClassifier {
  /// Total over `TerminalCause` on purpose: a new cause must choose its taxonomy value here rather
  /// than fall into a default that would quietly feed the evaluator or quietly starve it.
  static func classify(_ cause: TerminalCause) -> LearningEligibility {
    switch cause {
    case .taskCompleted:
      .eligibleTaskEvidence
    case .providerFailure, .storageFailure, .budgetStopped:
      .transientInfrastructureFailure
    case .policyBlocked:
      .policyOrSecurityBlock
    case .approvalUnresolved, .approvalDenied, .ownerCancelled, .superseded:
      .ownerInterruption
    case .incomplete:
      .insufficientEvidence
    case .unknown:
      .unsupportedTerminalState
    }
  }
}
