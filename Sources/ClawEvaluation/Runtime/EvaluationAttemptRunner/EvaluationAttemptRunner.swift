import ClawAgent
import ClawCore
import Foundation

struct EvaluationAttemptRunner: Sendable {
  private let roster: ProviderRoster
  private let httpRecorder: EvaluationHTTPRecorder
  private let progressRecorder: EvaluationAttemptProgressRecorder?
  private let processUUID: UUID
  private let now: @Sendable () -> Date
  private let providerCallIDGenerator: any ProviderCallIDGenerating
  private let runtimeNow: @Sendable () -> ContinuousClock.Instant
  private let memoryStore: any MemoryStore

  package init(
    roster: ProviderRoster,
    httpRecorder: EvaluationHTTPRecorder,
    progressRecorder: EvaluationAttemptProgressRecorder? = nil,
    processUUID: UUID = UUID(),
    now: @escaping @Sendable () -> Date = Date.init,
    providerCallIDGenerator: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator(),
    runtimeNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
    memoryStore: any MemoryStore = EmptyMemoryStore()
  ) {
    self.roster = roster
    self.httpRecorder = httpRecorder
    self.progressRecorder = progressRecorder
    self.processUUID = processUUID
    self.now = now
    self.providerCallIDGenerator = providerCallIDGenerator
    self.runtimeNow = runtimeNow
    self.memoryStore = memoryStore
  }

  // One linear attempt transaction keeps timestamps, usage, and recorded side effects bound to the
  // same outcome; extracting partial ownership would make that invariant implicit.
  // swiftlint:disable:next function_body_length
  package func run(
    configuration: EvaluationAttemptConfiguration,
    sendBudget: EvaluationSendBudgetSnapshot,
    lockAcquisitionID: UUID? = nil,
    integrityAdmission: @escaping @Sendable () async -> ProviderRoundTripAdmission = { .allow }
  ) async throws -> EvaluationAttemptResult {
    try configuration.validate()
    if configuration.executionProfile != .scheduledLearningV1 {
      try sendBudget.validate()
    }
    try Self.validate(roster: roster, configuration: configuration)
    try Self.validateProductionPrompts(configuration.provenance)
    if let mismatch = EvaluationPolicyInspector.mismatch(for: configuration) {
      throw mismatch
    }
    let started = now()
    let learningMaterialization: EvaluationLearningTaskMaterialization?
    let workspace: EvaluationWorkspaceMaterialization
    if configuration.executionProfile == .scheduledLearningV1 {
      let materialization = try EvaluationWorkspaceMaterializer.resetLearning(
        configuration: configuration
      )
      learningMaterialization = materialization
      workspace = materialization.workspace
    } else {
      learningMaterialization = nil
      workspace = try EvaluationWorkspaceMaterializer.reset(configuration: configuration)
    }
    let initialTainted =
      learningMaterialization.map { materialization in
        Self.initialTainted(
          configuration: configuration,
          lessonSet: materialization.carrier.activeLessons
        )
      } ?? false
    let taskPrompt = try Self.verifiedTaskPrompt(configuration: configuration)
    let runID = Self.stableIdentifier("run:\(configuration.attemptID)")
    let sessionID = Self.stableIdentifier("session:\(configuration.attemptID)")
    let toolRecorder = EvaluationToolRecorder(
      progressRecorder: progressRecorder,
      attemptID: configuration.attemptID
    )
    let expectedInputFileName = configuration.expectedInputFileName
    let dispatcher = EvaluationToolDispatcher(
      workspaceRoot: configuration.workspaceRootURL,
      allowedFileName: expectedInputFileName,
      recorder: toolRecorder,
      recordsInitialTrust: configuration.executionProfile == .scheduledLearningV1
    )
    let buildResult = try Self.buildContext(
      configuration: configuration,
      taskPrompt: taskPrompt,
      sessionID: sessionID,
      dispatcher: dispatcher,
      memoryStore: memoryStore,
      learningMaterialization: learningMaterialization,
      initialTainted: initialTainted
    )

    let usageStore = EvaluationUsageStore(
      progressRecorder: progressRecorder,
      attemptID: configuration.attemptID
    )
    let auditLog = EvaluationAuditLog()
    let runtime = AgentRuntime(
      roster: roster,
      typingIndicator: NoopTypingIndicator(),
      draftStreamer: NoopRichDraftStreaming(),
      streamingEnabled: true,
      attemptPolicy: AttemptRuntimePolicy(
        streamingReattemptPolicy: .disabled,
        terminalValidationPolicy: PageEvaluationContract.terminalValidationPolicy,
        outputLimits: PageEvaluationContract.outputLimits,
        expectedWireModel: configuration.wireModel,
        roundTripAdmission: { context in
          let budgetAdmission = sendBudget.admission(context)
          guard budgetAdmission == .allow else {
            return budgetAdmission
          }
          return await integrityAdmission()
        }
      ),
      costResolver: CostResolver(
        priceTable: .empty,
        referenceUSDPerToken: PageEvaluationContract.runBudget.referenceUSDPerToken
      ),
      budget: PageEvaluationContract.runBudget,
      toolDispatcher: dispatcher,
      usageStore: usageStore,
      auditLog: auditLog,
      providerCallIDGenerator: providerCallIDGenerator,
      clock: ContinuousClock(),
      now: runtimeNow
    )

    let outcome = try await runtime.runTurn(
      runId: runID,
      sessionId: sessionID,
      chatId: 1,
      buildResult: buildResult,
      sessionTainted: initialTainted,
      hasPinnedLessons: buildResult.hasPinnedLessons,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0,
      origin: .scheduled,
      proactiveTodayUSD: 0
    )
    let tools = await toolRecorder.records()
    let observedHTTP = await httpRecorder.snapshot()
    let labeledFenceRecords = await httpRecorder.labeledFenceRecords()
    let learningCarrierVerified = Self.learningCarrierVerified(
      configuration: configuration,
      http: observedHTTP,
      records: labeledFenceRecords
    )
    let mapped = Self.map(
      outcome: outcome,
      tools: tools,
      http: observedHTTP,
      expectedInputFileName: expectedInputFileName,
      expectedInputSHA256: configuration.inputSHA256,
      usesLearningProfile: configuration.executionProfile == .scheduledLearningV1,
      learningCarrierVerified: learningCarrierVerified
    )
    var usageRows = usageStore.rows
    func appendTerminalUsageIfNeeded(_ usage: ProviderUsage) throws {
      guard usageRows.contains(where: { $0.providerCallID == usage.providerCallID }) == false else {
        return
      }
      try progressRecorder?.recordUsage(attemptID: configuration.attemptID, usage: usage)
      usageRows.append(usage)
    }
    switch outcome.result {
    case .completed(_, let usage, _):
      try appendTerminalUsageIfNeeded(usage)
    case .degraded(_, let usage?):
      try appendTerminalUsageIfNeeded(usage)
    case .suspended(_, let usage):
      try appendTerminalUsageIfNeeded(usage)
    case .degraded(_, nil), .budgetStopped:
      break
    }
    let unresolvedResponsesSends = max(0, observedHTTP.responsesSends.count - usageRows.count)
    let preservesPendingProxy: Bool =
      if case .degraded(.accountingFailed, nil) = outcome.result { true } else { false }
    if unresolvedResponsesSends > 0, preservesPendingProxy == false {
      try await httpRecorder.recordProvenNotStartedResponsesSends(unresolvedResponsesSends)
    }
    let http = await httpRecorder.snapshot()

    let finished = now()
    return EvaluationAttemptResult(
      configuration: configuration,
      processUUID: processUUID,
      processID: Int32(ProcessInfo.processInfo.processIdentifier),
      runID: runID,
      sessionID: sessionID,
      startedAt: Self.timestamp(started),
      finishedAt: Self.timestamp(finished),
      durationMilliseconds: Int64(max(0, finished.timeIntervalSince(started) * 1_000)),
      policyVersion: buildResult.policyVersion,
      outcome: mapped.outcome,
      criticalCode: mapped.criticalCode,
      rawOutput: mapped.rawOutput,
      modelObservations: outcome.attemptDiagnostics.modelObservations,
      http: http,
      outputCounts: outcome.attemptDiagnostics.outputCounts,
      tools: tools,
      audit: auditLog.records,
      usage: usageRows.map(EvaluationUsageRecord.init),
      accountedTokens: EvaluationResultAccounting.accountedTokens(
        responsesSends: http.responsesSends.count,
        provenNotStartedResponsesSends: http.provenNotStartedResponsesSends,
        usage: usageRows
      ),
      replacementDisposition: mapped.replacementDisposition,
      replacementReason: mapped.replacementReason,
      workspace: workspace,
      lockAcquisitionID: lockAcquisitionID,
      learningCarrierSHA256: learningMaterialization?.workspace.inputSHA256,
      learningLessonSetSHA256: learningMaterialization?.workspace.lessonSetDigest,
      learningInitialTainted: learningMaterialization.map { _ in initialTainted },
      learningCarrierVerified: learningMaterialization.map { _ in learningCarrierVerified }
    )
  }

  package static func initialTainted(
    configuration: EvaluationAttemptConfiguration,
    lessonSet: EvaluationLearningLessonSet
  ) -> Bool {
    configuration.executionProfile == .scheduledLearningV1
      && lessonSet.lessons.isEmpty == false
  }
}

// MARK: - Attempt Metadata

private extension EvaluationAttemptRunner {
  static func stableIdentifier(_ text: String) -> Int64 {
    let prefix = PolicyFingerprint.hash(parts: [text]).prefix(15)
    return Int64(prefix, radix: 16) ?? 1
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
