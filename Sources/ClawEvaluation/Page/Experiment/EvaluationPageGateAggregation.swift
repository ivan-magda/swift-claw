import ClawCore
import Foundation

struct EvaluationPageGateStatus {
  let outcome: EvaluationPageTerminalClassification
  let passed: Bool
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
      let outcome = EvaluationPageTerminalClassification(rawValue: outcomeValue),
      let passed = CanonicalJSON.boolean(result["passed"])
    else {
      throw EvaluationPagePipelineError.stageGateReceiptInvalid(stage.rawValue)
    }

    return EvaluationPageGateStatus(outcome: outcome, passed: passed)
  }
}
