import ClawCore
import Foundation

extension EvaluationPageExperiment {
  func finish(
    outcome: EvaluationPageTerminalClassification,
    canary: EvaluationController.Accumulator,
    page: EvaluationController.Accumulator,
    journal: EvaluationControllerJournal,
    paths: EvaluationController.PagePipelinePaths,
    developmentGate: URL? = nil,
    promotionReceipt: URL? = nil,
    regressionGate: URL? = nil,
    regressionJointUnsealReceipt: URL? = nil,
    sealedGate: URL? = nil,
    lifecycleReceipt: URL? = nil,
    jointUnsealReceipt: URL? = nil,
    synthesisRejectionReport: URL? = nil
  ) throws -> Data {
    let isIncomplete =
      page.stopReason != nil
      || outcome == .incompleteBatch
    let stopReason = page.stopReason ?? (isIncomplete ? "scored_stage_incomplete" : nil)

    try journal.finish(incomplete: isIncomplete)
    try EvaluationJSONFile.write(page.summary, to: paths.summary)

    let journalDigest = SHA256Digest.hex(
      try EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url)
    )
    let result = EvaluationPagePipelineResult(
      outcome: outcome,
      incomplete: isIncomplete,
      stopReason: stopReason,
      canarySummary: canary.summary,
      summary: isIncomplete
        ? terminal(
          page.summary,
          classification: .incompleteBatch,
          reason: stopReason ?? "scored_stage_incomplete"
        )
        : page.summary,
      developmentGateSHA256: try digestIfPresent(developmentGate),
      promotionReceiptSHA256: try digestIfPresent(promotionReceipt),
      regressionGateSHA256: try digestIfPresent(regressionGate),
      regressionJointUnsealReceiptSHA256: try digestIfPresent(
        regressionJointUnsealReceipt
      ),
      sealedGateSHA256: try digestIfPresent(sealedGate),
      journalSHA256: journalDigest,
      lifecycleReceiptSHA256: try digestIfPresent(lifecycleReceipt),
      jointUnsealReceiptSHA256: try digestIfPresent(jointUnsealReceipt),
      synthesisRejectionReportSHA256: try digestIfPresent(synthesisRejectionReport)
    )

    let data = try EvaluationCanonicalJSON.data(encoding: result)
    try EvaluationDurablePublication.publish(data, to: paths.result)

    return data
  }

  func writeTerminalResult(
    for error: any Error,
    journal: EvaluationControllerJournal,
    paths: EvaluationController.PagePipelinePaths
  ) throws {
    let failure = EvaluationPageTerminalFailureClassifier.failure(for: error)
    try writeTerminalResult(
      classification: failure.classification,
      reason: failure.reason,
      journal: journal,
      paths: paths
    )
  }

  private func writeTerminalResult(
    classification: EvaluationPageTerminalClassification,
    reason: String,
    journal: EvaluationControllerJournal,
    paths: EvaluationController.PagePipelinePaths
  ) throws {
    try journal.finish(incomplete: classification.isIncomplete)
    let canary = try summaryIfPresent(paths.canarySummary)
    let page = try summaryIfPresent(paths.summary)

    let result = EvaluationPagePipelineResult(
      outcome: classification,
      incomplete: classification.isIncomplete,
      stopReason: reason,
      canarySummary: terminal(canary, classification: classification, reason: reason),
      summary: terminal(page, classification: classification, reason: reason),
      developmentGateSHA256: try digestIfPresent(paths.developmentGate),
      promotionReceiptSHA256: try digestIfPresent(paths.promotionReceipt),
      regressionGateSHA256: try digestIfPresent(paths.regressionGate),
      regressionJointUnsealReceiptSHA256: try digestIfPresent(
        paths.regressionJointUnsealReceipt
      ),
      sealedGateSHA256: try digestIfPresent(paths.sealedGate),
      journalSHA256: SHA256Digest.hex(
        try EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url)
      ),
      lifecycleReceiptSHA256: try digestIfPresent(paths.lifecycleReceipt),
      jointUnsealReceiptSHA256: try digestIfPresent(paths.jointUnsealReceipt),
      synthesisRejectionReportSHA256: try digestIfPresent(paths.synthesisRejectionReport)
    )

    try EvaluationDurablePublication.publish(
      EvaluationCanonicalJSON.data(encoding: result),
      to: paths.result
    )
  }

  private func summaryIfPresent(_ url: URL) throws -> EvaluationControllerSummary {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return EvaluationControllerSummary(
        completedAttemptIDs: [],
        incomplete: true,
        stopReason: "pipeline_failure",
        attempts: 0,
        responsesSends: 0,
        fileReads: 0,
        accountedTokens: 0,
        replacements: 0
      )
    }
    return try EvaluationJSONFile.decode(EvaluationControllerSummary.self, from: url)
  }

  private func terminal(
    _ summary: EvaluationControllerSummary,
    classification: EvaluationPageTerminalClassification,
    reason: String
  ) -> EvaluationControllerSummary {
    EvaluationControllerSummary(
      completedAttemptIDs: summary.completedAttemptIDs,
      incomplete: classification.isIncomplete,
      stopReason: classification.isIncomplete ? summary.stopReason ?? reason : nil,
      attempts: summary.attempts,
      responsesSends: summary.responsesSends,
      fileReads: summary.fileReads,
      accountedTokens: summary.accountedTokens,
      replacements: summary.replacements
    )
  }

  private func digestIfPresent(_ url: URL?) throws -> String? {
    guard let url else {
      return nil
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }

    return SHA256Digest.hex(try EvaluationPathSecurity.readRegularSingleLinkFile(at: url))
  }
}
