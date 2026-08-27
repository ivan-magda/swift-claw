import ClawCore
import Foundation

struct EvaluationPageTerminalFailure: Equatable {
  let classification: EvaluationPageTerminalClassification
  let reason: String
}

enum EvaluationPageTerminalFailureClassifier {
  static func failure(
    for error: any Error
  ) -> EvaluationPageTerminalFailure {
    if let error = error as? EvaluationPagePipelineError {
      return terminalFailure(for: error)
    }

    if let error = error as? EvaluationWorkspaceError {
      switch error.failureReason.classification {
      case .carrierFailure:
        return terminalFailure(.carrierFailure, reason: error.failureReason.rawValue)
      case .invalidBatch:
        return terminalFailure(.invalidBatch, reason: error.failureReason.rawValue)
      default:
        return terminalFailure(.invalidBatch, reason: "workspace_failure_classification")
      }
    }

    if error is CancellationError {
      return terminalFailure(.incompleteBatch, reason: "controller_cancelled")
    }

    if error is EvaluationPathSecurityError {
      return terminalFailure(.invalidBatch, reason: "evaluation_path_integrity_failure")
    }

    return terminalFailure(.invalidBatch, reason: "unclassified_harness_failure")
  }

  private static func terminalFailure(
    for error: EvaluationPagePipelineError
  ) -> EvaluationPageTerminalFailure {
    switch error {
    case .invalidBatch(let reason):
      return terminalFailure(.invalidBatch, reason: reason)
    case .carrierFailure(let reason):
      return terminalFailure(.carrierFailure, reason: reason)
    case .safetyFailure(let reason):
      return terminalFailure(.safetyFailure, reason: reason)
    case .taskSpecificFailure(let reason):
      return terminalFailure(.pageTaskSpecificFailure, reason: reason)
    case .incompleteBatch(let reason):
      return terminalFailure(.incompleteBatch, reason: reason)
    case .canaryEvidenceMissing:
      return terminalFailure(.carrierFailure, reason: "canary_carrier_evidence_missing")
    case .restartBoundaryFailed:
      return terminalFailure(.carrierFailure, reason: "restart_boundary_failed")
    case .resultUnavailable(let reason):
      return terminalFailure(.incompleteBatch, reason: "required_result_unavailable:\(reason)")
    case .synthesisFailed(let reason) where incompleteSynthesisReasons.contains(reason):
      return terminalFailure(.incompleteBatch, reason: "synthesis_\(reason)")
    default:
      return terminalIntegrityFailure(for: error)
    }
  }

  private static func terminalIntegrityFailure(
    for error: EvaluationPagePipelineError
  ) -> EvaluationPageTerminalFailure {
    switch error {
    case .invalidManifestContract:
      return terminalFailure(.invalidBatch, reason: "invalid_manifest_contract")
    case .invalidRunOrder:
      return terminalFailure(.invalidBatch, reason: "invalid_run_order")
    case .missingProtectedArtifact(let path):
      return terminalFailure(.invalidBatch, reason: "missing_protected_artifact:\(path)")
    case .protectedArtifactChanged(let path):
      return terminalFailure(.invalidBatch, reason: "protected_artifact_changed:\(path)")
    case .protectedArtifactFailed(let path):
      return terminalFailure(.invalidBatch, reason: "protected_artifact_failed:\(path)")
    case .protectedOutputExists(let path):
      return terminalFailure(.invalidBatch, reason: "protected_output_exists:\(path)")
    case .protectedOutputMissing(let path):
      return terminalFailure(.invalidBatch, reason: "protected_output_missing:\(path)")
    default:
      return terminalContractFailure(for: error)
    }
  }

  private static func terminalContractFailure(
    for error: EvaluationPagePipelineError
  ) -> EvaluationPageTerminalFailure {
    switch error {
    case .stageGateFailed(let stage):
      return terminalFailure(.invalidBatch, reason: "stage_gate_failed:\(stage)")
    case .stageGateReceiptInvalid(let stage):
      return terminalFailure(.invalidBatch, reason: "stage_gate_receipt_invalid:\(stage)")
    case .synthesisFailed(let reason):
      return terminalFailure(.invalidBatch, reason: "synthesis_contract_failed:\(reason)")
    case .promotionFailed:
      return terminalFailure(.invalidBatch, reason: "promotion_contract_failed")
    case .recordConstructionFailed(let attemptID):
      return terminalFailure(.invalidBatch, reason: "record_construction_failed:\(attemptID)")
    case .invalidBatch, .carrierFailure, .safetyFailure, .taskSpecificFailure,
      .incompleteBatch, .invalidManifestContract, .canaryEvidenceMissing, .invalidRunOrder,
      .missingProtectedArtifact, .protectedArtifactChanged, .protectedArtifactFailed,
      .protectedOutputExists, .protectedOutputMissing, .resultUnavailable, .restartBoundaryFailed:
      return terminalFailure(.invalidBatch, reason: "unclassified_harness_failure")
    }
  }

  private static func terminalFailure(
    _ classification: EvaluationPageTerminalClassification,
    reason: String
  ) -> EvaluationPageTerminalFailure {
    EvaluationPageTerminalFailure(classification: classification, reason: reason)
  }

  private static let incompleteSynthesisReasons: Set<String> = [
    "budget", "missing_output", "replacement", "replacement_budget", "runtime",
  ]
}
