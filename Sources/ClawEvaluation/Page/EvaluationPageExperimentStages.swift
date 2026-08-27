import ClawCore
import Foundation

struct EvaluationPageGateStatus {
  let outcome: String
  let passed: Bool
}

struct EvaluationSynthesisExecution {
  let result: EvaluationAttemptResult
  let attempts: [[String: Any]]
}

private struct EvaluationSynthesisReplacementRequest: Sendable {
  let configuration: EvaluationAttemptConfiguration
  let configurationURL: URL
  let inputURL: URL
  let executable: String
  let inputs: EvaluationFreezeInputs
  let freeze: EvaluationFreezeContext
  let journal: EvaluationControllerJournal
}

struct EvaluationPageTerminalFailure: Equatable {
  let classification: EvaluationPageTerminalClassification
  let reason: String
}

enum EvaluationLessonPromotionOutcome: Equatable {
  case promoted(EvaluationPagePromotionReceipt)
  case rejected
}

extension EvaluationPageExperiment {
  func prepare(_ paths: EvaluationController.PagePipelinePaths) throws {
    for directory in [paths.root, paths.configurations, paths.results, paths.receipts] {
      try EvaluationPathSecurity.ensurePrivateDirectory(at: directory)
    }
  }

  func unsealed(
    _ accepted: [EvaluationController.AcceptedAttempt]
  ) throws -> [EvaluationRecordedAttempt] {
    try accepted.map { item in
      guard case .result(let result) = item.payload else {
        throw EvaluationPagePipelineError.recordConstructionFailed("unexpected_sealed_result")
      }

      let configuration = try EvaluationJSONFile.decode(
        EvaluationAttemptConfiguration.self,
        from: URL(fileURLWithPath: item.actualConfigurationPath)
      )
      let data = try EvaluationPathSecurity.readRegularSingleLinkFile(
        at: configuration.resultURL
      )

      return EvaluationRecordedAttempt(
        result: result,
        resultOrEnvelopeSHA256: SHA256Digest.hex(data),
        originalAttemptEvidenceSHA256: item.originalAttemptEvidenceSHA256
      )
    }
  }

  func sealedReceipt(
    in accepted: [EvaluationController.AcceptedAttempt],
    orderKey: String
  ) throws -> EvaluationSealedAttemptReceipt {
    guard
      let item = accepted.first(where: { accepted in
        switch accepted.payload {
        case .sealed(let receipt): receipt.frozenOrderKey == orderKey
        case .result: false
        }
      }),
      case .sealed(let receipt) = item.payload
    else {
      throw EvaluationPagePipelineError.restartBoundaryFailed
    }
    return receipt
  }

  func buildSynthesisInput(
    freeze: EvaluationFreezeContext,
    paths: EvaluationController.PagePipelinePaths
  ) async throws {
    guard
      let feedbackGeneratorSHA256 = freeze.manifest.categories["feedback"]?.sha256,
      SHA256Digest.isCanonicalHex(feedbackGeneratorSHA256)
    else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }

    _ = try await artifacts.run(
      relativeExecutablePath: "\(EvaluationController.pageRootPath)/artifacts/page-synthesis",
      arguments: [
        "--runs", paths.developmentRuns.path,
        "--development-bundle", paths.developmentBundle.path,
        "--error-codes",
        try protectedPath(
          "\(EvaluationController.pageRootPath)/contracts/error-codes.json",
          freeze: freeze
        ),
        "--feedback-templates",
        try protectedPath(
          "\(EvaluationController.pageRootPath)/contracts/feedback-templates.json",
          freeze: freeze
        ),
        "--lesson-schema",
        try protectedPath(
          "\(EvaluationController.pageRootPath)/schemas/lesson-set.schema.json",
          freeze: freeze
        ),
        "--lint-rules",
        try protectedPath(
          "\(EvaluationController.pageRootPath)/contracts/lesson-lint-rules.json",
          freeze: freeze
        ),
        "--feedback-generator-sha256", feedbackGeneratorSHA256,
        "--output", paths.synthesisInput.path,
      ],
      protectedOutputURLs: [paths.synthesisInput],
      freeze: freeze,
      captureLimit: 128 * 1_024
    )

    guard FileManager.default.fileExists(atPath: paths.synthesisInput.path) else {
      throw EvaluationPagePipelineError.synthesisFailed("input")
    }
  }

  func runSynthesis(
    factory: EvaluationPageConfigurationFactory,
    slot: EvaluationPageSynthesisSlot,
    executable: String,
    inputs: EvaluationFreezeInputs,
    freeze: EvaluationFreezeContext,
    journal: EvaluationControllerJournal,
    page: inout EvaluationController.Accumulator,
    paths: EvaluationController.PagePipelinePaths
  ) async throws -> EvaluationSynthesisExecution {
    let original = try factory.makeSynthesisConfiguration(
      slot: slot,
      synthesisInputURL: paths.synthesisInput
    )
    let replacement = try factory.makeSynthesisConfiguration(
      slot: slot,
      synthesisInputURL: paths.synthesisInput,
      replacementOf: original.attemptID
    )
    let originalURL = paths.configurations.appendingPathComponent("\(original.attemptID).json")
    let replacementURL = paths.configurations.appendingPathComponent(
      "\(replacement.attemptID).json"
    )
    try EvaluationJSONFile.write(original, to: originalURL)
    try EvaluationJSONFile.write(replacement, to: replacementURL)
    try EvaluationController.validateReplacement(
      at: replacementURL.path,
      of: originalURL.path
    )

    guard page.within(PageEvaluationContract.pageLimits) else {
      throw EvaluationPagePipelineError.synthesisFailed("budget")
    }

    var transcript: [[String: Any]] = []
    let first = try await controller.runOne(
      executablePath: executable,
      configurationPath: originalURL.path,
      freezeInputs: inputs,
      freeze: freeze,
      limits: PageEvaluationContract.pageLimits,
      sealedOutputKey: nil,
      journal: journal,
      accumulator: &page
    )

    guard page.stopReason == nil else {
      throw EvaluationPagePipelineError.incompleteBatch(
        page.stopReason ?? "synthesis_budget_exhausted"
      )
    }

    let replacementRequest = EvaluationSynthesisReplacementRequest(
      configuration: replacement,
      configurationURL: replacementURL,
      inputURL: paths.synthesisInput,
      executable: executable,
      inputs: inputs,
      freeze: freeze,
      journal: journal
    )

    let completed: EvaluationAttemptResult
    switch first {
    case .result(let result) where result.replacementDisposition == .ineligible:
      let raw = try completedSynthesisOutput(result)
      try validateSynthesisInput(original, at: paths.synthesisInput)
      transcript.append(
        synthesisTranscriptAttempt(
          index: 1,
          attemptID: result.attemptID,
          result: result,
          rawOutput: raw
        )
      )
      completed = result
    case .result(let result) where result.replacementDisposition == .eligible:
      try validateSynthesisInput(original, at: paths.synthesisInput)
      transcript.append(
        synthesisTranscriptAttempt(
          index: 1,
          attemptID: result.attemptID,
          result: result,
          rawOutput: nil
        )
      )
      completed = try await runSynthesisReplacement(
        request: replacementRequest,
        page: &page,
        transcript: &transcript
      )
    case .result(let result):
      _ = try completedSynthesisOutput(result)
      throw EvaluationPagePipelineError.invalidBatch("synthesis_replacement_contract")
    case .missing:
      try validateSynthesisInput(original, at: paths.synthesisInput)
      transcript.append(
        synthesisTranscriptAttempt(
          index: 1,
          attemptID: original.attemptID,
          result: nil,
          rawOutput: nil
        )
      )
      completed = try await runSynthesisReplacement(
        request: replacementRequest,
        page: &page,
        transcript: &transcript
      )
    default:
      throw EvaluationPagePipelineError.invalidBatch("synthesis_sealed_result")
    }

    guard let raw = completed.rawOutput else {
      throw EvaluationPagePipelineError.synthesisFailed("missing_output")
    }
    try EvaluationDurablePublication.publish(Data(raw.utf8), to: paths.synthesisCandidate)

    return EvaluationSynthesisExecution(result: completed, attempts: transcript)
  }

  private func runSynthesisReplacement(
    request: EvaluationSynthesisReplacementRequest,
    page: inout EvaluationController.Accumulator,
    transcript: inout [[String: Any]]
  ) async throws -> EvaluationAttemptResult {
    guard
      page.replacements < PageEvaluationContract.pageLimits.replacementPool,
      page.within(PageEvaluationContract.pageLimits)
    else {
      throw EvaluationPagePipelineError.synthesisFailed("replacement_budget")
    }
    page.replacements += 1

    let launched = try await controller.runOne(
      executablePath: request.executable,
      configurationPath: request.configurationURL.path,
      freezeInputs: request.inputs,
      freeze: request.freeze,
      limits: PageEvaluationContract.pageLimits,
      sealedOutputKey: nil,
      journal: request.journal,
      accumulator: &page
    )

    guard page.stopReason == nil else {
      throw EvaluationPagePipelineError.incompleteBatch(
        page.stopReason ?? "synthesis_budget_exhausted"
      )
    }

    guard case .result(let result) = launched else {
      throw EvaluationPagePipelineError.incompleteBatch("synthesis_replacement_interrupted")
    }

    guard result.replacementDisposition == .ineligible else {
      _ = try completedSynthesisOutput(result)
      throw EvaluationPagePipelineError.invalidBatch("synthesis_replacement_contract")
    }

    let raw = try completedSynthesisOutput(result)
    try validateSynthesisInput(request.configuration, at: request.inputURL)
    transcript.append(
      synthesisTranscriptAttempt(
        index: 2,
        attemptID: result.attemptID,
        result: result,
        rawOutput: raw
      )
    )

    return result
  }

  private func validateSynthesisInput(
    _ configuration: EvaluationAttemptConfiguration,
    at inputURL: URL
  ) throws {
    let inputData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: inputURL)
    guard SHA256Digest.hex(inputData) == configuration.inputSHA256 else {
      throw EvaluationPagePipelineError.invalidBatch("synthesis_input_digest")
    }
  }

  private func completedSynthesisOutput(_ result: EvaluationAttemptResult) throws -> String {
    switch result.outcome {
    case .completed:
      guard let output = result.rawOutput else {
        throw EvaluationPagePipelineError.invalidBatch("synthesis_output_missing")
      }
      return output
    case .authenticationRequired, .accessDenied, .quotaLimited, .providerFailure:
      throw EvaluationPagePipelineError.incompleteBatch("synthesis_provider_access")
    case .modelIdentityMismatch, .invalidProviderState, .policyMismatch, .harnessFailure:
      throw EvaluationPagePipelineError.invalidBatch("synthesis_runtime_integrity")
    case .toolContractFailure:
      switch result.criticalCode.flatMap(EvaluationToolViolation.init(rawValue:)) {
      case .unexpectedTool, .unexpectedFileReadPath, .unexpectedSuspension:
        throw EvaluationPagePipelineError.safetyFailure("synthesis_task_contract")
      default:
        throw EvaluationPagePipelineError.taskSpecificFailure(
          result.criticalCode ?? "synthesis_tool_contract"
        )
      }
    case .budgetStopped:
      if result.criticalCode == nil {
        throw EvaluationPagePipelineError.incompleteBatch(result.replacementReason)
      }
      throw EvaluationPagePipelineError.taskSpecificFailure(
        result.criticalCode ?? "synthesis_budget_stop"
      )
    case .localOutputLimit:
      throw EvaluationPagePipelineError.taskSpecificFailure("synthesis_local_output_limit")
    }
  }

  private func synthesisTranscriptAttempt(
    index: Int,
    attemptID: String,
    result: EvaluationAttemptResult?,
    rawOutput: String?
  ) -> [String: Any] {
    [
      "attempt_id": attemptID,
      "attempt_index": index,
      "conversation_id": result.map { $0.conversationID as Any } ?? NSNull(),
      "process_uuid": result.map { $0.processUUID.uuidString.lowercased() as Any } ?? NSNull(),
      "raw_output": rawOutput.map { $0 as Any } ?? NSNull(),
      "runtime_outcome": rawOutput == nil ? "transport_failure" : "completed",
    ]
  }

  private func writeSynthesisTranscript(
    attempts: [[String: Any]],
    configuration: EvaluationAttemptResult,
    freeze: EvaluationFreezeContext,
    paths: EvaluationController.PagePipelinePaths,
    lintReport: [String: Any]
  ) throws {
    guard
      let prompt = freeze.manifest.artifact(role: "synthesis", category: "prompts"),
      let feedbackDigest = freeze.manifest.categories["feedback"]?.sha256
    else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }

    let promptData: Data
    do {
      promptData = try EvaluationManifestBoundArtifactReader.read(
        relativePath: prompt.path,
        expectedByteCount: prompt.bytes,
        expectedSHA256: prompt.sha256,
        repositoryRoot: URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
      ).data
    } catch {
      throw EvaluationPagePipelineError.protectedArtifactChanged(prompt.path)
    }

    guard
      prompt.sha256 == configuration.taskPromptSHA256,
      let promptText = String(data: promptData, encoding: .utf8)
    else {
      throw EvaluationPagePipelineError.protectedArtifactChanged(prompt.path)
    }

    let inputData = try EvaluationPathSecurity.readRegularSingleLinkFile(
      at: paths.synthesisInput
    )
    guard
      let input = try JSONSerialization.jsonObject(with: inputData) as? [String: Any],
      let selected = input["selected_target_classes"] as? [String],
      selected.isEmpty == false
    else {
      throw EvaluationPagePipelineError.synthesisFailed("input_provenance")
    }

    let canonicalInput = try EvaluationCanonicalJSON.data(fromJSONObject: input)
    let canonicalLint = try EvaluationCanonicalJSON.data(fromJSONObject: lintReport)
    guard canonicalInput == inputData else {
      throw EvaluationPagePipelineError.synthesisFailed("input_provenance")
    }

    try EvaluationDurablePublication.publish(
      EvaluationCanonicalJSON.data(fromJSONObject: [
        "attempts": attempts,
        "feedback_generator_sha256": feedbackDigest,
        "feedback_generator_version": PageEvaluationContract.feedbackGeneratorVersion,
        "lint_report": lintReport,
        "lint_report_sha256": SHA256Digest.hex(canonicalLint),
        "provider_reference": configuration.providerReference,
        "schema_version": 1,
        "selected_target_classes": selected,
        "synthesis_input": input,
        "synthesis_input_sha256": SHA256Digest.hex(inputData),
        "synthesis_prompt": promptText,
        "synthesis_prompt_sha256": prompt.sha256,
        "wire_model": configuration.wireModel,
      ]),
      to: paths.synthesisTranscript
    )
  }

  private func writeSynthesisRejectionReport(
    synthesis: EvaluationAttemptResult,
    lintReport: [String: Any],
    freeze: EvaluationFreezeContext,
    paths: EvaluationController.PagePipelinePaths
  ) throws {
    let errors = lintReport["errors"] as? [[String: Any]] ?? []
    let codes = errors.compactMap { $0["code"] as? String }

    let report: [String: Any] = [
      "attempt_id": synthesis.attemptID,
      "candidate_sha256": SHA256Digest.hex(
        try EvaluationPathSecurity.readRegularSingleLinkFile(at: paths.synthesisCandidate)
      ),
      "lint_report_sha256": SHA256Digest.hex(
        try EvaluationPathSecurity.readRegularSingleLinkFile(at: paths.lintReport)
      ),
      "manifest_sha256": freeze.receipt.manifest.sha256,
      "outcome": "page_task_specific_failure",
      "provider_reference": synthesis.providerReference,
      "rejection_codes": codes,
      "schema_version": 1,
      "synthesis_input_sha256": SHA256Digest.hex(
        try EvaluationPathSecurity.readRegularSingleLinkFile(at: paths.synthesisInput)
      ),
      "synthesis_transcript_sha256": SHA256Digest.hex(
        try EvaluationPathSecurity.readRegularSingleLinkFile(at: paths.synthesisTranscript)
      ),
      "wire_model": synthesis.wireModel,
    ]

    try EvaluationDurablePublication.publish(
      EvaluationCanonicalJSON.data(fromJSONObject: report),
      to: paths.synthesisRejectionReport
    )
  }

  func promote(
    synthesis: EvaluationSynthesisExecution,
    freeze: EvaluationFreezeContext,
    paths: EvaluationController.PagePipelinePaths
  ) async throws -> EvaluationLessonPromotionOutcome {
    guard synthesis.result.rawOutput != nil else {
      throw EvaluationPagePipelineError.promotionFailed
    }

    let lint = try await artifacts.run(
      relativeExecutablePath: "\(EvaluationController.pageRootPath)/artifacts/page-lesson-lint",
      arguments: [
        "--candidate", paths.synthesisCandidate.path,
        "--synthesis-input", paths.synthesisInput.path,
        "--development-bundle", paths.developmentBundle.path,
      ],
      protectedOutputURLs: [],
      freeze: freeze,
      captureLimit: 256 * 1_024
    )

    guard let report = try JSONSerialization.jsonObject(with: lint) as? [String: Any],
      CanonicalJSON.boolean(report["accepted"]) != nil,
      try EvaluationCanonicalJSON.data(fromJSONObject: report) == lint
    else {
      throw EvaluationPagePipelineError.promotionFailed
    }

    try EvaluationDurablePublication.publish(lint, to: paths.lintReport)
    try writeSynthesisTranscript(
      attempts: synthesis.attempts,
      configuration: synthesis.result,
      freeze: freeze,
      paths: paths,
      lintReport: report
    )

    guard CanonicalJSON.boolean(report["accepted"]) == true else {
      try writeSynthesisRejectionReport(
        synthesis: synthesis.result,
        lintReport: report,
        freeze: freeze,
        paths: paths
      )
      return .rejected
    }

    _ = try await artifacts.run(
      relativeExecutablePath: "\(EvaluationController.pageRootPath)/artifacts/page-promotion",
      arguments: [
        "--synthesis-input", paths.synthesisInput.path,
        "--development-bundle", paths.developmentBundle.path,
        "--lint-rules",
        try protectedPath(
          "\(EvaluationController.pageRootPath)/contracts/lesson-lint-rules.json",
          freeze: freeze
        ),
        "--synthesis-transcript", paths.synthesisTranscript.path,
        "--lint-report", paths.lintReport.path,
        "--artifact-output", paths.promotedTemporary.path,
        "--receipt-output", paths.promotionReceipt.path,
      ],
      protectedOutputURLs: [paths.promotedTemporary, paths.promotionReceipt],
      freeze: freeze,
      captureLimit: 128 * 1_024
    )

    let active = try EvaluationPathSecurity.readRegularSingleLinkFile(
      at: paths.promotedTemporary
    )

    do {
      let receipt = try EvaluationPagePromotionReceipt.load(from: paths.promotionReceipt)
      try receipt.validateFrozenProvenance(against: freeze)
      _ = try receipt.validatedActiveLessonSetDigest(active)
      return .promoted(receipt)
    } catch {
      throw EvaluationPagePipelineError.promotionFailed
    }
  }

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
      let outcome = result["outcome"] as? String,
      let passed = CanonicalJSON.boolean(result["passed"])
    else {
      throw EvaluationPagePipelineError.stageGateReceiptInvalid(stage.rawValue)
    }

    return EvaluationPageGateStatus(outcome: outcome, passed: passed)
  }

  func protectedPath(_ relative: String, freeze: EvaluationFreezeContext) throws -> String {
    guard let record = freeze.manifest.artifact(relativePath: relative) else {
      throw EvaluationPagePipelineError.missingProtectedArtifact(relative)
    }

    do {
      return try EvaluationManifestBoundArtifactReader.read(
        relativePath: record.path,
        expectedByteCount: record.bytes,
        expectedSHA256: record.sha256,
        repositoryRoot: URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
      ).url.path
    } catch {
      throw EvaluationPagePipelineError.protectedArtifactChanged(relative)
    }
  }

  func finish(
    outcome: String,
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
      || outcome == EvaluationPageTerminalClassification.incompleteBatch.rawValue
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
    let failure = Self.terminalFailure(for: error)
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
      outcome: classification.rawValue,
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

  static func terminalFailure(
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
