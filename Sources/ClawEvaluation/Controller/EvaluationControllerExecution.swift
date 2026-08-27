import ClawCore
import Foundation

// swiftlint:disable file_length

extension EvaluationController {
  enum AttemptLaunchOutcome {
    case result(EvaluationAttemptResult)
    case sealed(EvaluationSealedAttemptReceipt)
    case missing(originalAttemptEvidenceSHA256: String)
  }

  enum AcceptedAttemptPayload: Sendable {
    case result(EvaluationAttemptResult)
    case sealed(EvaluationSealedAttemptReceipt)
  }

  struct AcceptedAttempt: Sendable {
    let originalConfigurationPath: String
    let actualConfigurationPath: String
    let originalAttemptEvidenceSHA256: String?
    let originalSealedReceipt: EvaluationSealedAttemptReceipt?
    let payload: AcceptedAttemptPayload

    init(
      originalConfigurationPath: String,
      actualConfigurationPath: String,
      originalAttemptEvidenceSHA256: String? = nil,
      originalSealedReceipt: EvaluationSealedAttemptReceipt? = nil,
      payload: AcceptedAttemptPayload
    ) {
      self.originalConfigurationPath = originalConfigurationPath
      self.actualConfigurationPath = actualConfigurationPath
      self.originalAttemptEvidenceSHA256 = originalAttemptEvidenceSHA256
      self.originalSealedReceipt = originalSealedReceipt
      self.payload = payload
    }
  }

  struct ReplacementPlan {
    let originalConfigurationPath: String
    let replacementConfigurationPath: String
    let originalAttemptEvidenceSHA256: String
    let originalSealedReceipt: EvaluationSealedAttemptReceipt?
  }

  private struct AttemptExecutionContext {
    let executablePath: String
    let freezeInputs: EvaluationFreezeInputs
    let freeze: EvaluationFreezeContext
    let limits: PageEvaluationContract.StageLimits
    let sealedOutputKey: Data?
    let journal: EvaluationControllerJournal
  }

  private struct OriginalBlockOutcome {
    var accepted: [AcceptedAttempt] = []
    var replacements: [ReplacementPlan] = []
    var stopped = false
  }

  private struct ReplacementBlockOutcome {
    var accepted: [AcceptedAttempt] = []
    var stopped = false
  }

  private enum OriginalAttemptDisposition {
    case accepted(AcceptedAttempt)
    case replacement(ReplacementPlan)
    case stopped
  }

  private struct LaunchedAttempt {
    let configuration: EvaluationAttemptConfiguration
    let invocation: WrittenInvocation
    let launchResult: EvaluationWorkerLaunchResult
    let journalKind: EvaluationControllerJournalEventKind
    let progress: EvaluationAttemptProgressRecord?
  }

  private struct AdmittedAttempt {
    let outcome: AttemptLaunchOutcome
    let attemptID: String
    let responsesSends: Int
    let fileReads: Int
    let accountedTokens: Int
  }

  struct Accumulator {
    var completedAttemptIDs: [String] = []
    var stopReason: String?
    var attempts = 0
    var responsesSends = 0
    var fileReads = 0
    var accountedTokens = 0
    var replacements = 0
    var globalAccountedTokensBase = 0
    var globalResponsesSendsBase = 0
    var globalAttemptsBase = 0
    var globalFileReadsBase = 0

    var summary: EvaluationControllerSummary {
      EvaluationControllerSummary(
        completedAttemptIDs: completedAttemptIDs,
        incomplete: stopReason != nil,
        stopReason: stopReason,
        attempts: attempts,
        responsesSends: responsesSends,
        fileReads: fileReads,
        accountedTokens: accountedTokens,
        replacements: replacements
      )
    }

    func within(
      _ limits: PageEvaluationContract.StageLimits,
      reservingResponsesSends: Int = PageEvaluationContract.maximumResponsesSendsPerAttempt
    ) -> Bool {
      attempts < limits.maximumAttempts
        && responsesSends <= limits.maximumResponsesSends - reservingResponsesSends
        && fileReads < limits.maximumFileReads
        && accountedTokens < limits.accountedTokenThreshold
        && SaturatingArithmetic.sum(globalAttemptsBase, attempts)
          < PageEvaluationContract.globalMaximumAttempts
        && SaturatingArithmetic.sum(globalFileReadsBase, fileReads)
          < PageEvaluationContract.globalMaximumFileReads
        && SaturatingArithmetic.sum(globalResponsesSendsBase, responsesSends)
          <= PageEvaluationContract.globalMaximumResponsesSends - reservingResponsesSends
        && SaturatingArithmetic.sum(globalAccountedTokensBase, accountedTokens)
          < PageEvaluationContract.globalAccountedTokenThreshold
    }

    func sendBudget(
      for limits: PageEvaluationContract.StageLimits
    ) -> EvaluationSendBudgetSnapshot {
      EvaluationSendBudgetSnapshot(
        stageAccountedTokens: accountedTokens,
        globalAccountedTokens: SaturatingArithmetic.sum(
          globalAccountedTokensBase,
          accountedTokens
        ),
        stageResponsesSends: responsesSends,
        globalResponsesSends: SaturatingArithmetic.sum(
          globalResponsesSendsBase,
          responsesSends
        ),
        stageAccountedTokenThreshold: limits.accountedTokenThreshold,
        stageResponsesSendCap: limits.maximumResponsesSends
      )
    }
  }

  // swiftlint:disable:next function_parameter_count
  func executeBlocks(
    _ blocks: [EvaluationReplicateBlock],
    executablePath: String,
    freezeInputs: EvaluationFreezeInputs,
    freeze: EvaluationFreezeContext,
    limits: PageEvaluationContract.StageLimits,
    sealedOutputKey: Data?,
    journal: EvaluationControllerJournal,
    accumulator: inout Accumulator
  ) async throws -> [AcceptedAttempt] {
    let context = AttemptExecutionContext(
      executablePath: executablePath,
      freezeInputs: freezeInputs,
      freeze: freeze,
      limits: limits,
      sealedOutputKey: sealedOutputKey,
      journal: journal
    )
    var accepted: [AcceptedAttempt] = []
    for block in blocks {
      let originals = try await executeOriginalAttempts(
        block,
        context: context,
        accumulator: &accumulator
      )
      accepted.append(contentsOf: originals.accepted)
      guard originals.stopped == false else {
        break
      }
      let replacements = try await executeReplacementAttempts(
        originals.replacements,
        context: context,
        accumulator: &accumulator
      )
      accepted.append(contentsOf: replacements.accepted)
      guard replacements.stopped == false else {
        break
      }
    }
    return accepted
  }

  private func executeOriginalAttempts(
    _ block: EvaluationReplicateBlock,
    context: AttemptExecutionContext,
    accumulator: inout Accumulator
  ) async throws -> OriginalBlockOutcome {
    var outcome = OriginalBlockOutcome()
    for planned in block.attempts {
      if let replacementPath = planned.replacementConfigurationPath {
        try Self.validateReplacement(at: replacementPath, of: planned.configurationPath)
      }
      guard Self.reserveLaunch(limits: context.limits, accumulator: &accumulator) else {
        outcome.stopped = true
        return outcome
      }
      let launched = try await runOne(
        configurationPath: planned.configurationPath,
        context: context,
        accumulator: &accumulator
      )
      switch try Self.disposition(
        for: launched,
        planned: planned,
        accumulator: &accumulator
      ) {
      case .accepted(let accepted):
        outcome.accepted.append(accepted)
      case .replacement(let replacement):
        outcome.replacements.append(replacement)
      case .stopped:
        outcome.stopped = true
        return outcome
      }
    }
    return outcome
  }

  private func executeReplacementAttempts(
    _ replacements: [ReplacementPlan],
    context: AttemptExecutionContext,
    accumulator: inout Accumulator
  ) async throws -> ReplacementBlockOutcome {
    var outcome = ReplacementBlockOutcome()
    for replacement in replacements {
      guard accumulator.replacements < context.limits.replacementPool else {
        accumulator.stopReason = "replacement_pool_exhausted"
        outcome.stopped = true
        return outcome
      }
      guard Self.reserveLaunch(limits: context.limits, accumulator: &accumulator) else {
        outcome.stopped = true
        return outcome
      }
      accumulator.replacements += 1
      let launched = try await runOne(
        configurationPath: replacement.replacementConfigurationPath,
        context: context,
        accumulator: &accumulator
      )
      guard
        let replacement = try Self.acceptReplacement(
          launched,
          plan: replacement,
          accumulator: &accumulator
        )
      else {
        outcome.stopped = true
        return outcome
      }
      outcome.accepted.append(replacement)
    }
    return outcome
  }

  private static func reserveLaunch(
    limits: PageEvaluationContract.StageLimits,
    accumulator: inout Accumulator
  ) -> Bool {
    guard accumulator.stopReason == nil, accumulator.within(limits) else {
      if accumulator.stopReason == nil {
        accumulator.stopReason = "stage_budget_exhausted"
      }
      return false
    }
    return true
  }

  private static func disposition(
    for launched: AttemptLaunchOutcome,
    planned: EvaluationPlannedAttempt,
    accumulator: inout Accumulator
  ) throws -> OriginalAttemptDisposition {
    switch launched {
    case .missing(let evidenceSHA256):
      return replacementDisposition(
        planned: planned,
        evidenceSHA256: evidenceSHA256,
        sealedReceipt: nil,
        accumulator: &accumulator
      )
    case .result(let result):
      return try disposition(for: result, planned: planned, accumulator: &accumulator)
    case .sealed(let receipt):
      return try disposition(for: receipt, planned: planned, accumulator: &accumulator)
    }
  }

  private static func disposition(
    for result: EvaluationAttemptResult,
    planned: EvaluationPlannedAttempt,
    accumulator: inout Accumulator
  ) throws -> OriginalAttemptDisposition {
    if isIntegrityFailure(result) {
      throw EvaluationPagePipelineError.invalidBatch("attempt_integrity_failure")
    }
    if result.replacementDisposition == .eligible {
      return replacementDisposition(
        planned: planned,
        evidenceSHA256: try resultEvidenceSHA256(
          configurationPath: planned.configurationPath,
          sealed: false
        ),
        sealedReceipt: nil,
        accumulator: &accumulator
      )
    }
    guard isIncompleteFailure(result) == false else {
      accumulator.stopReason = "attempt_provider_access_failure"
      return .stopped
    }
    return .accepted(
      AcceptedAttempt(
        originalConfigurationPath: planned.configurationPath,
        actualConfigurationPath: planned.configurationPath,
        payload: .result(result)
      )
    )
  }

  private static func disposition(
    for receipt: EvaluationSealedAttemptReceipt,
    planned: EvaluationPlannedAttempt,
    accumulator: inout Accumulator
  ) throws -> OriginalAttemptDisposition {
    if isIntegrityFailure(receipt.outcome) {
      throw EvaluationPagePipelineError.invalidBatch("attempt_integrity_failure")
    }
    if receipt.replacementDisposition == .eligible {
      return replacementDisposition(
        planned: planned,
        evidenceSHA256: receipt.envelopeSHA256,
        sealedReceipt: receipt,
        accumulator: &accumulator
      )
    }
    guard isIncompleteFailure(receipt) == false else {
      accumulator.stopReason = "attempt_provider_access_failure"
      return .stopped
    }
    return .accepted(
      AcceptedAttempt(
        originalConfigurationPath: planned.configurationPath,
        actualConfigurationPath: planned.configurationPath,
        payload: .sealed(receipt)
      )
    )
  }

  private static func replacementDisposition(
    planned: EvaluationPlannedAttempt,
    evidenceSHA256: String,
    sealedReceipt: EvaluationSealedAttemptReceipt?,
    accumulator: inout Accumulator
  ) -> OriginalAttemptDisposition {
    guard let replacementPath = planned.replacementConfigurationPath else {
      accumulator.stopReason = "eligible_attempt_has_no_replacement"
      return .stopped
    }
    return .replacement(
      ReplacementPlan(
        originalConfigurationPath: planned.configurationPath,
        replacementConfigurationPath: replacementPath,
        originalAttemptEvidenceSHA256: evidenceSHA256,
        originalSealedReceipt: sealedReceipt
      )
    )
  }

  private static func acceptReplacement(
    _ launched: AttemptLaunchOutcome,
    plan: ReplacementPlan,
    accumulator: inout Accumulator
  ) throws -> AcceptedAttempt? {
    switch launched {
    case .missing:
      accumulator.stopReason = "replacement_process_interrupted"
      return nil
    case .result(let result):
      guard result.replacementDisposition != .eligible else {
        accumulator.stopReason = "replacement_remained_eligible"
        return nil
      }
      if isIntegrityFailure(result) {
        throw EvaluationPagePipelineError.invalidBatch("attempt_integrity_failure")
      }
      guard isIncompleteFailure(result) == false else {
        accumulator.stopReason = "attempt_provider_access_failure"
        return nil
      }
      return acceptedReplacement(plan: plan, payload: .result(result))
    case .sealed(let receipt):
      if isIntegrityFailure(receipt.outcome) {
        throw EvaluationPagePipelineError.invalidBatch("attempt_integrity_failure")
      }
      guard isIncompleteFailure(receipt) == false else {
        accumulator.stopReason = "attempt_provider_access_failure"
        return nil
      }
      guard receipt.replacementDisposition != .eligible else {
        accumulator.stopReason = "replacement_remained_eligible"
        return nil
      }
      return acceptedReplacement(plan: plan, payload: .sealed(receipt))
    }
  }

  private static func acceptedReplacement(
    plan: ReplacementPlan,
    payload: AcceptedAttemptPayload
  ) -> AcceptedAttempt {
    AcceptedAttempt(
      originalConfigurationPath: plan.originalConfigurationPath,
      actualConfigurationPath: plan.replacementConfigurationPath,
      originalAttemptEvidenceSHA256: plan.originalAttemptEvidenceSHA256,
      originalSealedReceipt: plan.originalSealedReceipt,
      payload: payload
    )
  }

  // swiftlint:disable:next function_parameter_count
  func runOne(
    executablePath: String,
    configurationPath: String,
    freezeInputs: EvaluationFreezeInputs,
    freeze: EvaluationFreezeContext,
    limits: PageEvaluationContract.StageLimits,
    sealedOutputKey: Data?,
    journal: EvaluationControllerJournal,
    accumulator: inout Accumulator
  ) async throws -> AttemptLaunchOutcome {
    try await runOne(
      configurationPath: configurationPath,
      context: AttemptExecutionContext(
        executablePath: executablePath,
        freezeInputs: freezeInputs,
        freeze: freeze,
        limits: limits,
        sealedOutputKey: sealedOutputKey,
        journal: journal
      ),
      accumulator: &accumulator
    )
  }

  private func runOne(
    configurationPath: String,
    context: AttemptExecutionContext,
    accumulator: inout Accumulator
  ) async throws -> AttemptLaunchOutcome {
    let launched = try await launchAttempt(
      configurationPath: configurationPath,
      context: context,
      accumulator: &accumulator
    )
    switch launched.launchResult.termination {
    case .completed:
      return try Self.completeAttempt(
        launched,
        context: context,
        accumulator: &accumulator
      )
    case .interrupted:
      return try Self.reconcileInterruptedAttempt(
        launched,
        context: context,
        accumulator: &accumulator
      )
    case .rejected:
      return try Self.rejectAttempt(
        launched,
        context: context,
        accumulator: &accumulator
      )
    }
  }

  // swiftlint:disable:next function_body_length
  private func launchAttempt(
    configurationPath: String,
    context: AttemptExecutionContext,
    accumulator: inout Accumulator
  ) async throws -> LaunchedAttempt {
    let configurationURL = URL(fileURLWithPath: configurationPath)
    let configuration = try EvaluationJSONFile.decode(
      EvaluationAttemptConfiguration.self,
      from: configurationURL
    )
    try configuration.validate()
    try Self.validate(configuration: configuration, against: context.freeze)
    guard FileManager.default.fileExists(atPath: configuration.resultURL.path) == false else {
      throw EvaluationControllerError.staleResultExists
    }
    try EvaluationProtectedOutputGuard.prepare(
      outputs: [EvaluationWorkerFailureEvidence.url(for: configuration.resultURL)]
    )
    accumulator.attempts += 1
    guard
      try await freezeVerifier.verifyLocal(context.freezeInputs).hasSameApprovedBinding(
        as: context.freeze
      )
    else {
      throw EvaluationControllerError.freezeChangedBeforeLaunch
    }
    let invocation = try Self.writeInvocation(
      kind: .attempt,
      configurationPath: configurationPath,
      freeze: context.freezeInputs,
      budget: accumulator.sendBudget(for: context.limits),
      evaluationRoot: context.freeze.runtime.evaluationRootURL,
      journal: context.journal,
      attemptIDs: [configuration.attemptID],
      maximumResponsesSends: PageEvaluationContract.maximumResponsesSendsPerAttempt
    )
    try EvaluationProtectedOutputGuard.prepare(
      outputs: [
        try EvaluationAttemptProgressRecorder.url(
          invocationID: invocation.invocationID,
          configurations: [configuration]
        )
      ]
    )
    let launched = await launcher.launch(
      kind: .attempt,
      executablePath: context.executablePath,
      invocationPath: invocation.path,
      sealedOutputKey: configuration.requiresJointUnseal ? context.sealedOutputKey : nil
    )
    let journalKind = Self.journalKind(for: launched.termination)
    let progress: EvaluationAttemptProgressRecord?
    do {
      progress = try EvaluationAttemptProgressRecorder.loadIfPresent(
        invocationID: invocation.invocationID,
        invocationConfigurationSHA256: invocation.configurationSHA256,
        configurations: [configuration]
      )
    } catch {
      try context.journal.recordLaunch(
        kind: journalKind,
        invocationID: invocation.invocationID,
        attemptIDs: [configuration.attemptID],
        observedResponsesSends: nil,
        observedFileReads: nil,
        observedAccountedTokens: nil,
        processID: launched.processID
      )
      throw EvaluationPagePipelineError.invalidBatch("attempt_progress_invalid")
    }
    return LaunchedAttempt(
      configuration: configuration,
      invocation: invocation,
      launchResult: launched,
      journalKind: journalKind,
      progress: progress
    )
  }

  private static func journalKind(
    for termination: EvaluationWorkerTermination
  ) -> EvaluationControllerJournalEventKind {
    switch termination {
    case .completed: .launchCompleted
    case .interrupted: .launchInterrupted
    case .rejected: .launchRejected
    }
  }

  private static func completeAttempt(
    _ launched: LaunchedAttempt,
    context: AttemptExecutionContext,
    accumulator: inout Accumulator
  ) throws -> AttemptLaunchOutcome {
    do {
      if let admitted = try admitOutputIfPresent(
        launched,
        context: context,
        accumulator: &accumulator,
      ) {
        return admitted
      }
    } catch {
      try accountProgressIfNeeded(launched, context: context, accumulator: &accumulator)
      throw error
    }
    try accountProgress(launched, context: context, accumulator: &accumulator)
    throw EvaluationControllerError.resultIdentityMismatch
  }

  private static func reconcileInterruptedAttempt(
    _ launched: LaunchedAttempt,
    context: AttemptExecutionContext,
    accumulator: inout Accumulator
  ) throws -> AttemptLaunchOutcome {
    do {
      if let admitted = try admitOutputIfPresent(
        launched,
        context: context,
        accumulator: &accumulator
      ) {
        return admitted
      }
    } catch {
      try accountProgressIfNeeded(launched, context: context, accumulator: &accumulator)
      throw error
    }
    let event = try accountProgress(launched, context: context, accumulator: &accumulator)
    try throwTerminalErrorIfPresent(launched)
    return .missing(originalAttemptEvidenceSHA256: try evidenceSHA256(event))
  }

  private static func rejectAttempt(
    _ launched: LaunchedAttempt,
    context: AttemptExecutionContext,
    accumulator: inout Accumulator
  ) throws -> AttemptLaunchOutcome {
    try accountProgress(launched, context: context, accumulator: &accumulator)
    try throwTerminalErrorIfPresent(launched)
    throw EvaluationPagePipelineError.invalidBatch(
      launched.launchResult.processID == nil ? "worker_start_failed" : "worker_nonzero_exit"
    )
  }

  private static func accountProgressIfNeeded(
    _ launched: LaunchedAttempt,
    context: AttemptExecutionContext,
    accumulator: inout Accumulator
  ) throws {
    guard
      accumulator.completedAttemptIDs.contains(launched.configuration.attemptID) == false
    else {
      return
    }
    try accountProgress(launched, context: context, accumulator: &accumulator)
  }

  @discardableResult
  private static func accountProgress(
    _ launched: LaunchedAttempt,
    context: AttemptExecutionContext,
    accumulator: inout Accumulator
  ) throws -> EvaluationControllerJournalEvent {
    try accountAndRecordProgress(
      launched.progress,
      configurations: [launched.configuration],
      kind: launched.journalKind,
      invocationID: launched.invocation.invocationID,
      processID: launched.launchResult.processID,
      journal: context.journal,
      accumulator: &accumulator,
      limits: context.limits
    )
  }

  private static func throwTerminalErrorIfPresent(_ launched: LaunchedAttempt) throws {
    if let error = try EvaluationWorkerFailureEvidence.terminalErrorIfPresent(
      invocationID: launched.invocation.invocationID,
      configurationSHA256: launched.invocation.configurationSHA256,
      configurations: [launched.configuration]
    ) {
      throw error
    }
  }

  private static func admitOutputIfPresent(
    _ launched: LaunchedAttempt,
    context: AttemptExecutionContext,
    accumulator: inout Accumulator
  ) throws -> AttemptLaunchOutcome? {
    let admitted: AdmittedAttempt?
    if launched.configuration.requiresJointUnseal {
      admitted = try admittedSealedOutput(
        configuration: launched.configuration,
        progress: launched.progress,
        sealedOutputKey: context.sealedOutputKey
      )
    } else {
      admitted = try admittedPlainOutput(
        configuration: launched.configuration,
        progress: launched.progress
      )
    }
    guard let admitted else {
      return nil
    }
    accumulator.completedAttemptIDs.append(admitted.attemptID)
    accumulator.responsesSends = SaturatingArithmetic.sum(
      accumulator.responsesSends,
      admitted.responsesSends
    )
    accumulator.fileReads = SaturatingArithmetic.sum(
      accumulator.fileReads,
      admitted.fileReads
    )
    accumulator.accountedTokens = SaturatingArithmetic.sum(
      accumulator.accountedTokens,
      admitted.accountedTokens
    )
    try context.journal.recordLaunch(
      kind: launched.journalKind,
      invocationID: launched.invocation.invocationID,
      attemptIDs: [launched.configuration.attemptID],
      observedResponsesSends: admitted.responsesSends,
      observedFileReads: admitted.fileReads,
      observedAccountedTokens: admitted.accountedTokens,
      processID: launched.launchResult.processID
    )
    terminalizeAfterResult(&accumulator, limits: context.limits)
    return admitted.outcome
  }

  private static func admittedSealedOutput(
    configuration: EvaluationAttemptConfiguration,
    progress: EvaluationAttemptProgressRecord?,
    sealedOutputKey: Data?
  ) throws -> AdmittedAttempt? {
    let envelopeURL = EvaluationSealedResultStore.envelopeURL(for: configuration.resultURL)
    let receiptURL = EvaluationSealedResultStore.receiptURL(for: configuration.resultURL)
    let plaintextExists = FileManager.default.fileExists(atPath: configuration.resultURL.path)
    let envelopeExists = FileManager.default.fileExists(atPath: envelopeURL.path)
    let receiptExists = FileManager.default.fileExists(atPath: receiptURL.path)
    if plaintextExists == false, envelopeExists == false, receiptExists == false { return nil }
    guard
      plaintextExists == false,
      envelopeExists,
      receiptExists,
      sealedOutputKey != nil
    else {
      throw EvaluationPagePipelineError.invalidBatch("sealed_attempt_output_incomplete")
    }
    let receipt: EvaluationSealedAttemptReceipt
    do {
      receipt = try EvaluationJSONFile.decode(EvaluationSealedAttemptReceipt.self, from: receiptURL)
    } catch {
      throw EvaluationPagePipelineError.invalidBatch("sealed_attempt_receipt_invalid")
    }
    guard sealedReceipt(receipt, matches: configuration) else {
      throw EvaluationPagePipelineError.invalidBatch("sealed_attempt_identity")
    }
    guard
      progress?.attempts.count == 1,
      let progressEntry = progress?.attempts.first,
      Self.progressEntry(progressEntry, matches: receipt)
    else {
      throw EvaluationControllerError.resultProgressMismatch
    }
    let envelope: Data
    do {
      envelope = try EvaluationPathSecurity.readRegularSingleLinkFile(at: envelopeURL)
    } catch {
      throw EvaluationPagePipelineError.invalidBatch("sealed_attempt_envelope_invalid")
    }
    guard SHA256Digest.hex(envelope) == receipt.envelopeSHA256 else {
      throw EvaluationPagePipelineError.invalidBatch("sealed_attempt_envelope_invalid")
    }
    return AdmittedAttempt(
      outcome: .sealed(receipt),
      attemptID: receipt.attemptID,
      responsesSends: receipt.responsesSends,
      fileReads: receipt.fileReads,
      accountedTokens: receipt.accountedTokens
    )
  }

  private static func admittedPlainOutput(
    configuration: EvaluationAttemptConfiguration,
    progress: EvaluationAttemptProgressRecord?
  ) throws -> AdmittedAttempt? {
    guard FileManager.default.fileExists(atPath: configuration.resultURL.path) else {
      return nil
    }
    let result: EvaluationAttemptResult
    do {
      result = try EvaluationJSONFile.decode(
        EvaluationAttemptResult.self,
        from: configuration.resultURL
      )
    } catch {
      throw EvaluationPagePipelineError.invalidBatch("attempt_result_invalid")
    }
    guard Self.result(result, matches: configuration) else {
      throw EvaluationPagePipelineError.invalidBatch("attempt_result_identity")
    }
    guard
      progress?.attempts.count == 1,
      let progressEntry = progress?.attempts.first,
      Self.progressEntry(
        progressEntry,
        matches: result,
        expectedInputFileName: configuration.expectedInputFileName
      )
    else {
      throw EvaluationControllerError.resultProgressMismatch
    }
    return AdmittedAttempt(
      outcome: .result(result),
      attemptID: result.attemptID,
      responsesSends: result.http.responsesSends.count,
      fileReads: EvaluationToolContract.observedFileReads(
        in: result.tools,
        expectedPath: configuration.expectedInputFileName
      ),
      accountedTokens: result.accountedTokens
    )
  }

  @discardableResult
  // swiftlint:disable:next function_parameter_count
  static func accountAndRecordProgress(
    _ progress: EvaluationAttemptProgressRecord?,
    configurations: [EvaluationAttemptConfiguration],
    kind: EvaluationControllerJournalEventKind,
    invocationID: UUID,
    processID: Int32?,
    journal: EvaluationControllerJournal,
    accumulator: inout Accumulator,
    limits: PageEvaluationContract.StageLimits
  ) throws -> EvaluationControllerJournalEvent {
    let entries = progress?.attempts ?? []
    let sends = entries.reduce(0) { SaturatingArithmetic.sum($0, $1.responsesSends) }
    let fileReads = entries.reduce(0) { SaturatingArithmetic.sum($0, $1.fileReads) }
    let tokens = entries.reduce(0) { SaturatingArithmetic.sum($0, $1.accountedTokens) }
    accumulator.responsesSends = SaturatingArithmetic.sum(accumulator.responsesSends, sends)
    accumulator.fileReads = SaturatingArithmetic.sum(accumulator.fileReads, fileReads)
    accumulator.accountedTokens = SaturatingArithmetic.sum(accumulator.accountedTokens, tokens)
    let event = try journal.recordLaunch(
      kind: kind,
      invocationID: invocationID,
      attemptIDs: configurations.map(\.attemptID),
      observedResponsesSends: sends,
      observedFileReads: fileReads,
      observedAccountedTokens: tokens,
      processID: processID
    )
    Self.terminalizeAfterResult(&accumulator, limits: limits)
    return event
  }
}
