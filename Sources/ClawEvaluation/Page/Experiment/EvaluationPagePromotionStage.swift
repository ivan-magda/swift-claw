import ClawCore
import Foundation

enum EvaluationLessonPromotionOutcome: Equatable {
  case promoted(EvaluationPagePromotionReceipt)
  case rejected
}

extension EvaluationPageExperiment {
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
}
