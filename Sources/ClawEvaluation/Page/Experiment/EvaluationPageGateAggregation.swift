import ClawCore
import Foundation

struct EvaluationPageGateStatus {
  let decision: EvaluationPageGateDecision
}

enum EvaluationPageGateDecision: Sendable, Equatable {
  case proceed
  case finish(EvaluationPageTerminalClassification)
}

enum EvaluationPageGateOutcome: String, Sendable, Equatable {
  case carrierFailure = "carrier_failure"
  case developmentReady = "development_ready"
  case incompleteBatch = "incomplete_batch"
  case insufficientDevelopmentHeadroom = "insufficient_development_headroom"
  case insufficientSealedHeadroom = "insufficient_sealed_headroom"
  case invalidBatch = "invalid_batch"
  case pageTaskSpecificFailure = "page_task_specific_failure"
  case pageValidated = "page_validated"
  case regressionPromoted = "regression_promoted"
  case regressionPromotedNotTestable = "regression_promoted_not_testable"
  case safetyFailure = "safety_failure"

  var passed: Bool {
    switch self {
    case .developmentReady, .regressionPromoted, .regressionPromotedNotTestable, .pageValidated:
      true
    default:
      false
    }
  }

  func decision(for stage: EvaluationPageSplit) -> EvaluationPageGateDecision? {
    switch (stage, self) {
    case (.development, .developmentReady),
      (.regression, .regressionPromoted),
      (.regression, .regressionPromotedNotTestable):
      .proceed
    case (.development, .insufficientDevelopmentHeadroom):
      .finish(.insufficientDevelopmentHeadroom)
    case (.sealed, .insufficientSealedHeadroom):
      .finish(.insufficientSealedHeadroom)
    case (.sealed, .pageValidated):
      .finish(.pageValidated)
    case (_, .invalidBatch):
      .finish(.invalidBatch)
    case (_, .carrierFailure):
      .finish(.carrierFailure)
    case (_, .safetyFailure):
      .finish(.safetyFailure)
    case (_, .pageTaskSpecificFailure):
      .finish(.pageTaskSpecificFailure)
    case (_, .incompleteBatch):
      .finish(.incompleteBatch)
    default:
      nil
    }
  }
}

extension EvaluationPageExperiment {
  func aggregate(
    stage: EvaluationPageSplit,
    records: URL,
    output: URL,
    inputs: EvaluationFreezeInputs,
    freeze: EvaluationFreezeContext,
    paths: EvaluationController.PagePipelinePaths
  ) async throws -> EvaluationPageGateStatus {
    var arguments = [
      stage.rawValue,
      "--root", freeze.repositoryRoot,
      "--manifest", inputs.manifestPath,
      "--approved-manifest-sha256", freeze.receipt.manifest.sha256,
      "--approved-freeze-commit", freeze.receipt.freezeCommit,
      "--run-order", paths.runOrder.path,
      "--records", records.path,
      "--conformance-receipt", paths.conformance.path,
    ]

    if stage == .regression || stage == .sealed {
      arguments += [
        "--development-receipt", paths.developmentGate.path,
        "--development-records", paths.developmentRecords.path,
        "--synthesis-input", paths.synthesisInput.path,
        "--development-bundle", paths.developmentBundle.path,
        "--synthesis-transcript", paths.synthesisTranscript.path,
        "--lint-report", paths.lintReport.path,
        "--promotion-receipt", paths.promotionReceipt.path,
        "--active-lesson-set", paths.promotedTemporary.path,
      ]
    }

    if stage == .sealed {
      arguments += [
        "--regression-receipt", paths.regressionGate.path,
        "--regression-records", paths.regressionRecords.path,
        "--lifecycle-receipt", paths.lifecycleReceipt.path,
      ]
    }
    arguments += ["--output", output.path]

    _ = try await artifacts.run(
      relativeExecutablePath: "\(EvaluationController.pageRootPath)/artifacts/page-aggregate",
      arguments: arguments,
      protectedOutputURLs: [output],
      freeze: freeze,
      captureLimit: 512 * 1_024
    )
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: output)

    guard
      let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      receipt["stage"] as? String == stage.rawValue,
      let result = receipt["result"] as? [String: Any],
      let outcomeValue = result["outcome"] as? String,
      let outcome = EvaluationPageGateOutcome(rawValue: outcomeValue),
      let passed = CanonicalJSON.boolean(result["passed"]),
      passed == outcome.passed,
      let decision = outcome.decision(for: stage)
    else {
      throw EvaluationPagePipelineError.stageGateReceiptInvalid(stage.rawValue)
    }

    return EvaluationPageGateStatus(decision: decision)
  }
}
