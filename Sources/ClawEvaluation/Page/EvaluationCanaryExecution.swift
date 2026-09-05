import ClawCore
import Foundation

struct EvaluationCanaryEvidence: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let processAUUID: UUID
  let processBUUID: UUID
  let attemptIDs: [String]
  let conversationIDs: [String]
  let durableLessonDigest: String
  let durableLessonSetID: String
  let durableLessonIDs: [String]
  let policyVersion: String
  let untrustedFenceWasApplied: Bool
  let workspaceWasEmpty: Bool
  let inputWasRegenerated: Bool

  init(results: [EvaluationAttemptResult]) throws {
    guard
      results.count == PageEvaluationContract.canaryPlannedAttempts,
      results[0].processUUID == results[1].processUUID,
      results[2].processUUID == results[3].processUUID,
      results[0].processUUID != results[2].processUUID,
      results[0].lockAcquisitionID != nil,
      results[0].lockAcquisitionID == results[1].lockAcquisitionID,
      results[2].lockAcquisitionID != nil,
      results[2].lockAcquisitionID == results[3].lockAcquisitionID,
      results[0].lockAcquisitionID != results[2].lockAcquisitionID,
      Set(results.map(\.conversationID)).count == PageEvaluationContract.canaryPlannedAttempts,
      results.allSatisfy(Self.validRuntimeResult),
      results.map(\.outcome).allSatisfy({ $0 == .completed }),
      results.map(\.criticalCode).allSatisfy({ $0 == nil }),
      results.map(\.rawOutput).allSatisfy({ $0 != nil }),
      results.map(\.workspace.inputWasRegenerated).allSatisfy({ $0 }),
      results.map(\.policyVersion).allSatisfy({ $0 == results[0].policyVersion }),
      results[0].workspace.carrierReceipt.lessonSource == .clean,
      results[1].workspace.carrierReceipt.lessonSource == .artifact,
      results[2].workspace.carrierReceipt.lessonSource == .clean,
      results[3].workspace.carrierReceipt.lessonSource == .durableActive,
      results[0].lessonSetID == "empty",
      results[0].lessonIDs.isEmpty,
      results[2].lessonSetID == results[0].lessonSetID,
      results[2].lessonIDs == results[0].lessonIDs,
      results[1].lessonSetDigest == results[3].lessonSetDigest,
      results[1].lessonSetID == results[3].lessonSetID,
      results[1].lessonIDs == results[3].lessonIDs,
      results[1].lessonIDs.isEmpty == false,
      results[1].inputSHA256 == results[3].inputSHA256,
      results.allSatisfy({ result in
        result.http.responsesSends.count
          == PageEvaluationContract.maximumResponsesSendsPerAttempt
          && result.http.responsesSends[1].untrustedFencePresent
      }),
      results[2].workspace.workspaceWasEmptyAtStart,
      results[2].workspace.inputWasRegenerated,
      results[3].workspace.inputWasRegenerated
    else {
      throw EvaluationPagePipelineError.canaryEvidenceMissing
    }
    schemaVersion = PageEvaluationContract.schemaVersion
    processAUUID = results[0].processUUID
    processBUUID = results[2].processUUID
    attemptIDs = results.map(\.attemptID)
    conversationIDs = results.map(\.conversationID)
    durableLessonDigest = results[3].lessonSetDigest
    durableLessonSetID = results[3].lessonSetID
    durableLessonIDs = results[3].lessonIDs
    policyVersion = results[3].policyVersion
    untrustedFenceWasApplied = results.allSatisfy { result in
      result.http.responsesSends.count == PageEvaluationContract.maximumResponsesSendsPerAttempt
        && result.http.responsesSends[1].untrustedFencePresent
    }
    workspaceWasEmpty = results[2].workspace.workspaceWasEmptyAtStart
    inputWasRegenerated =
      results[2].workspace.inputWasRegenerated
      && results[3].workspace.inputWasRegenerated
  }

  private static func validRuntimeResult(_ result: EvaluationAttemptResult) -> Bool {
    result.outcome == .completed
      && result.criticalCode == nil
      && result.rawOutput != nil
      && result.http.integrityFailures.isEmpty
      && result.http.responsesSends.count
        == PageEvaluationContract.maximumResponsesSendsPerAttempt
      && result.http.responsesSends.allSatisfy {
        $0.requestedModel == PageEvaluationContract.wireModel
      }
      && result.http.responsesSends[0].untrustedPayloadSHA256 == nil
      && result.http.responsesSends[1].untrustedPayloadSHA256 == result.inputSHA256
      && result.modelObservations.count
        == PageEvaluationContract.maximumCompletedModelRoundTripsPerAttempt
      && result.modelObservations.allSatisfy {
        $0.outboundModel == PageEvaluationContract.wireModel
          && ($0.terminalModel == nil || $0.terminalModel == PageEvaluationContract.wireModel)
      }
      && EvaluationToolContract.violation(in: result.tools) == nil
      && result.workspace.inputWasRegenerated
      && result.workspace.inputPath.hasSuffix("/\(PageEvaluationContract.inputFileName)")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case processAUUID = "process_a_uuid"
    case processBUUID = "process_b_uuid"
    case attemptIDs = "attempt_ids"
    case conversationIDs = "conversation_ids"
    case durableLessonDigest = "durable_lesson_digest"
    case durableLessonSetID = "durable_lesson_set_id"
    case durableLessonIDs = "durable_lesson_ids"
    case policyVersion = "policy_version"
    case untrustedFenceWasApplied = "untrusted_fence_was_applied"
    case workspaceWasEmpty = "workspace_was_empty"
    case inputWasRegenerated = "input_was_regenerated"
  }
}

struct EvaluationCanaryExecutionRequest {
  let order: EvaluationPageRunOrder
  let factory: EvaluationPageConfigurationFactory
  let executablePath: String
  let journal: EvaluationControllerJournal
  let configurationPaths: [URL]
  let evidenceURL: URL
}

extension EvaluationController {
  private enum CanaryDurableResults {
    case none
    case partial
    case complete([EvaluationAttemptResult])
  }

  private struct CanaryProcessExecution {
    let configurations: [EvaluationAttemptConfiguration]
    let invocation: WrittenInvocation
    let launched: EvaluationWorkerLaunchResult
    let journalKind: EvaluationControllerJournalEventKind
    let progress: EvaluationAttemptProgressRecord?
  }

  func executeCanary(
    _ request: EvaluationCanaryExecutionRequest,
    accumulator: inout Accumulator
  ) async throws -> EvaluationCanaryEvidence {
    guard
      request.order.canaryProcesses.count == PageEvaluationContract.canaryProcessCount,
      request.configurationPaths.count == PageEvaluationContract.canaryProcessCount
    else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    var allResults: [EvaluationAttemptResult] = []
    for (index, process) in request.order.canaryProcesses.enumerated() {
      let execution = try await launchCanaryProcess(
        process,
        at: index,
        request: request,
        accumulator: &accumulator
      )
      allResults.append(
        contentsOf: try Self.completeCanaryProcess(
          execution,
          request: request,
          accumulator: &accumulator
        )
      )
    }
    let evidence = try EvaluationCanaryEvidence(results: allResults)
    try EvaluationJSONFile.write(evidence, to: request.evidenceURL)
    return evidence
  }

  // swiftlint:disable:next function_body_length
  private func launchCanaryProcess(
    _ process: EvaluationPageCanaryProcessSlot,
    at index: Int,
    request: EvaluationCanaryExecutionRequest,
    accumulator: inout Accumulator
  ) async throws -> CanaryProcessExecution {
    let factory = request.factory
    let freeze = factory.freeze
    if index == 1 {
      try Self.rotateToEmptyWorkspace(
        freeze.runtime.workspaceRootURL,
        evaluationRoot: freeze.runtime.evaluationRootURL
      )
    }
    guard
      accumulator.within(
        PageEvaluationContract.canaryLimits,
        reservingResponsesSends: PageEvaluationContract.canaryResponsesSendsPerProcess
      )
    else {
      throw EvaluationPagePipelineError.incompleteBatch("canary_budget_exhausted")
    }
    let configurations = try factory.makeCanaryConfigurations(process: process)
    let configurationURLs = try configurations.map { configuration -> URL in
      let url = factory.configurationDirectory.appendingPathComponent(
        "\(configuration.attemptID).json"
      )
      try EvaluationJSONFile.write(configuration, to: url)
      return url
    }
    try EvaluationProtectedOutputGuard.prepare(
      outputs: configurations.map {
        EvaluationWorkerFailureEvidence.url(for: $0.resultURL)
      }
    )
    let batch = EvaluationWorkerBatchConfiguration(
      attemptConfigurationPaths: configurationURLs.map(\.path)
    )
    let batchURL = request.configurationPaths[index]
    try EvaluationJSONFile.write(batch, to: batchURL)
    accumulator.attempts = SaturatingArithmetic.sum(
      accumulator.attempts,
      PageEvaluationContract.canaryAttemptsPerProcess
    )
    let freezeInputs = factory.freezeInputs
    guard try await freezeVerifier.verify(freezeInputs).hasSameApprovedBinding(as: freeze)
    else {
      throw EvaluationControllerError.freezeChangedBeforeLaunch
    }
    let invocation = try Self.writeInvocation(
      kind: .canaryProcess,
      configurationPath: batchURL.path,
      freeze: freezeInputs,
      budget: accumulator.sendBudget(for: PageEvaluationContract.canaryLimits),
      evaluationRoot: freeze.runtime.evaluationRootURL,
      journal: request.journal,
      attemptIDs: configurations.map(\.attemptID),
      maximumResponsesSends: PageEvaluationContract.canaryResponsesSendsPerProcess
    )
    try EvaluationProtectedOutputGuard.prepare(
      outputs: [
        try EvaluationAttemptProgressRecorder.url(
          invocationID: invocation.invocationID,
          configurations: configurations
        )
      ]
    )
    try Self.verifyProtectedClosureBeforeLaunch(freeze)
    let launched = await launcher.launch(
      kind: .canaryProcess,
      executablePath: request.executablePath,
      invocationPath: invocation.path,
      credentialStateRoot: configurations[0].stateRootURL.path,
      sealedOutputKey: nil
    )
    let journalKind: EvaluationControllerJournalEventKind =
      switch launched.termination {
      case .completed: .launchCompleted
      case .interrupted: .launchInterrupted
      case .rejected: .launchRejected
      }
    let progress: EvaluationAttemptProgressRecord?
    do {
      progress = try EvaluationAttemptProgressRecorder.loadIfPresent(
        invocationID: invocation.invocationID,
        invocationConfigurationSHA256: invocation.configurationSHA256,
        configurations: configurations
      )
    } catch {
      try request.journal.recordLaunch(
        kind: journalKind,
        invocationID: invocation.invocationID,
        attemptIDs: configurations.map(\.attemptID),
        observedResponsesSends: nil,
        observedFileReads: nil,
        observedAccountedTokens: nil,
        processID: launched.processID
      )
      throw EvaluationPagePipelineError.invalidBatch("attempt_progress_invalid")
    }
    return CanaryProcessExecution(
      configurations: configurations,
      invocation: invocation,
      launched: launched,
      journalKind: journalKind,
      progress: progress
    )
  }

  private static func completeCanaryProcess(
    _ execution: CanaryProcessExecution,
    request: EvaluationCanaryExecutionRequest,
    accumulator: inout Accumulator
  ) throws -> [EvaluationAttemptResult] {
    let results = try requireCanaryResults(
      execution,
      request: request,
      accumulator: &accumulator
    )
    try admitCanaryResults(
      results,
      execution: execution,
      journal: request.journal,
      accumulator: &accumulator
    )
    guard Set(results.map(\.processUUID)).count == 1 else {
      throw EvaluationPagePipelineError.carrierFailure("canary_process_identity")
    }
    for result in results {
      try validateCanaryOutcome(result)
    }
    terminalizeAfterResult(&accumulator, limits: PageEvaluationContract.canaryLimits)
    guard accumulator.stopReason == nil else {
      throw EvaluationPagePipelineError.incompleteBatch(
        accumulator.stopReason ?? "canary_budget_exhausted"
      )
    }
    return results
  }

  private static func requireCanaryResults(
    _ execution: CanaryProcessExecution,
    request: EvaluationCanaryExecutionRequest,
    accumulator: inout Accumulator
  ) throws -> [EvaluationAttemptResult] {
    if execution.launched.termination == .rejected {
      try accountCanaryProgress(execution, journal: request.journal, accumulator: &accumulator)
      if let error = try EvaluationWorkerFailureEvidence.terminalErrorIfPresent(
        invocationID: execution.invocation.invocationID,
        configurationSHA256: execution.invocation.configurationSHA256,
        configurations: execution.configurations
      ) {
        throw error
      }
      throw EvaluationPagePipelineError.invalidBatch(
        execution.launched.processID == nil ? "canary_start_failed" : "canary_nonzero_exit"
      )
    }
    let durableResults: CanaryDurableResults
    do {
      durableResults = try loadCanaryResultsIfPresent(execution.configurations)
    } catch {
      try accountCanaryProgress(execution, journal: request.journal, accumulator: &accumulator)
      throw error
    }
    switch durableResults {
    case .partial:
      try accountCanaryProgress(execution, journal: request.journal, accumulator: &accumulator)
      guard execution.launched.termination == .interrupted else {
        throw EvaluationPagePipelineError.invalidBatch("canary_result_output_incomplete")
      }
      let reason = "canary_process_interrupted"
      accumulator.stopReason = reason
      throw EvaluationPagePipelineError.incompleteBatch(reason)
    case .none:
      try accountCanaryProgress(execution, journal: request.journal, accumulator: &accumulator)
      if execution.launched.termination == .interrupted {
        let reason = "canary_process_interrupted"
        accumulator.stopReason = reason
        throw EvaluationPagePipelineError.incompleteBatch(reason)
      }
      throw EvaluationPagePipelineError.invalidBatch("canary_result_output_missing")
    case .complete(let results):
      guard
        let progress = execution.progress,
        progress.attempts.count == execution.configurations.count,
        zip(progress.attempts, zip(execution.configurations, results)).allSatisfy({ item in
          progressEntry(
            item.0,
            matches: item.1.1,
            expectedInputFileName: item.1.0.expectedInputFileName
          )
        })
      else {
        try accountCanaryProgress(execution, journal: request.journal, accumulator: &accumulator)
        throw EvaluationControllerError.resultProgressMismatch
      }
      return results
    }
  }

  private static func accountCanaryProgress(
    _ execution: CanaryProcessExecution,
    journal: EvaluationControllerJournal,
    accumulator: inout Accumulator
  ) throws {
    try accountAndRecordProgress(
      execution.progress,
      configurations: execution.configurations,
      kind: execution.journalKind,
      invocationID: execution.invocation.invocationID,
      processID: execution.launched.processID,
      journal: journal,
      accumulator: &accumulator,
      limits: PageEvaluationContract.canaryLimits
    )
  }

  private static func loadCanaryResultsIfPresent(
    _ configurations: [EvaluationAttemptConfiguration]
  ) throws -> CanaryDurableResults {
    let present = configurations.map {
      FileManager.default.fileExists(atPath: $0.resultURL.path)
    }
    if present.allSatisfy({ $0 == false }) { return .none }
    guard present.allSatisfy({ $0 }) else {
      return .partial
    }
    return try .complete(
      configurations.map { configuration in
        let result: EvaluationAttemptResult
        do {
          result = try EvaluationJSONFile.decode(
            EvaluationAttemptResult.self,
            from: configuration.resultURL
          )
        } catch {
          throw EvaluationPagePipelineError.invalidBatch("canary_result_output_invalid")
        }
        guard Self.result(result, matches: configuration) else {
          throw EvaluationPagePipelineError.invalidBatch("canary_result_identity")
        }
        return result
      }
    )
  }

  private static func admitCanaryResults(
    _ results: [EvaluationAttemptResult],
    execution: CanaryProcessExecution,
    journal: EvaluationControllerJournal,
    accumulator: inout Accumulator
  ) throws {
    let sends = results.reduce(0) {
      SaturatingArithmetic.sum($0, $1.http.responsesSends.count)
    }
    let fileReads = zip(execution.configurations, results).reduce(0) { partial, item in
      SaturatingArithmetic.sum(
        partial,
        EvaluationToolContract.observedFileReads(
          in: item.1.tools,
          expectedPath: item.0.expectedInputFileName
        )
      )
    }
    let tokens = results.reduce(0) {
      SaturatingArithmetic.sum($0, $1.accountedTokens)
    }
    accumulator.responsesSends = SaturatingArithmetic.sum(accumulator.responsesSends, sends)
    accumulator.fileReads = SaturatingArithmetic.sum(accumulator.fileReads, fileReads)
    accumulator.accountedTokens = SaturatingArithmetic.sum(accumulator.accountedTokens, tokens)
    accumulator.completedAttemptIDs.append(contentsOf: results.map(\.attemptID))
    try journal.recordLaunch(
      kind: execution.journalKind,
      invocationID: execution.invocation.invocationID,
      attemptIDs: results.map(\.attemptID),
      observedResponsesSends: sends,
      observedFileReads: fileReads,
      observedAccountedTokens: tokens,
      processID: execution.launched.processID
    )
  }

  private static func validateCanaryOutcome(_ result: EvaluationAttemptResult) throws {
    switch result.outcome {
    case .completed:
      return
    case .authenticationRequired, .accessDenied, .quotaLimited, .providerFailure:
      throw EvaluationPagePipelineError.incompleteBatch("canary_provider_access")
    case .modelIdentityMismatch, .policyMismatch:
      throw EvaluationPagePipelineError.carrierFailure("canary_runtime_binding")
    case .invalidProviderState, .harnessFailure:
      throw EvaluationPagePipelineError.invalidBatch("canary_runtime_integrity")
    case .toolContractFailure:
      switch result.criticalCode.flatMap(EvaluationToolViolation.init(rawValue:)) {
      case .expectedOneFileRead, .fileReadFailed:
        throw EvaluationPagePipelineError.carrierFailure("canary_file_read_carrier")
      default:
        throw EvaluationPagePipelineError.safetyFailure("canary_tool_contract")
      }
    case .budgetStopped:
      if result.criticalCode == nil {
        throw EvaluationPagePipelineError.incompleteBatch(result.replacementReason)
      }
      throw EvaluationPagePipelineError.safetyFailure("canary_tool_contract")
    case .localOutputLimit:
      throw EvaluationPagePipelineError.incompleteBatch("canary_output_limit")
    }
  }

  /// Preserves the previous attempt workspace for audit while proving process B starts empty.
  static func rotateToEmptyWorkspace(_ workspace: URL, evaluationRoot: URL) throws {
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [evaluationRoot, workspace])
    if FileManager.default.fileExists(atPath: workspace.path) {
      let quarantine =
        evaluationRoot
        .appendingPathComponent("workspace-history", isDirectory: true)
        .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
      try EvaluationPathSecurity.ensurePrivateDirectory(at: quarantine.deletingLastPathComponent())
      try EvaluationPathSecurity.rejectSymlinkComponents(in: [quarantine])
      try FileManager.default.moveItem(at: workspace, to: quarantine)
    }
    try EvaluationPathSecurity.ensurePrivateDirectory(at: workspace)
    guard try FileManager.default.contentsOfDirectory(atPath: workspace.path).isEmpty else {
      throw EvaluationPagePipelineError.restartBoundaryFailed
    }
  }
}
