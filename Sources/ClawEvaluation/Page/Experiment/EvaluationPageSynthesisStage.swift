import ClawCore
import Foundation

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

extension EvaluationPageExperiment {
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
}
