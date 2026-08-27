import ClawAgent
import ClawCore
import ClawWorkspace
import Foundation

struct EvaluationAttemptRunner: Sendable {
  private let roster: ProviderRoster
  private let httpRecorder: EvaluationHTTPRecorder
  private let progressRecorder: EvaluationAttemptProgressRecorder?
  private let processUUID: UUID
  private let now: @Sendable () -> Date
  private let providerCallIDGenerator: any ProviderCallIDGenerating
  private let runtimeNow: @Sendable () -> ContinuousClock.Instant

  package init(
    roster: ProviderRoster,
    httpRecorder: EvaluationHTTPRecorder,
    progressRecorder: EvaluationAttemptProgressRecorder? = nil,
    processUUID: UUID = UUID(),
    now: @escaping @Sendable () -> Date = Date.init,
    providerCallIDGenerator: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator(),
    runtimeNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.roster = roster
    self.httpRecorder = httpRecorder
    self.progressRecorder = progressRecorder
    self.processUUID = processUUID
    self.now = now
    self.providerCallIDGenerator = providerCallIDGenerator
    self.runtimeNow = runtimeNow
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
    try sendBudget.validate()
    try Self.validate(roster: roster, configuration: configuration)
    try Self.validateProductionPrompts(configuration.provenance)
    if let mismatch = EvaluationPolicyInspector.mismatch(for: configuration) {
      throw mismatch
    }
    let started = now()
    let workspace = try EvaluationWorkspaceMaterializer.reset(configuration: configuration)
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
      recorder: toolRecorder
    )
    let buildResult = try Self.buildContext(
      configuration: configuration,
      taskPrompt: taskPrompt,
      sessionID: sessionID,
      dispatcher: dispatcher
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
          guard budgetAdmission == .allow else { return budgetAdmission }
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
      sessionTainted: false,
      sessionHasPrivateData: false,
      todayTokens: 0,
      todayUSD: 0,
      origin: .scheduled,
      proactiveTodayUSD: 0
    )
    let tools = await toolRecorder.records()
    let observedHTTP = await httpRecorder.snapshot()
    let mapped = Self.map(
      outcome: outcome,
      tools: tools,
      http: observedHTTP,
      expectedInputFileName: expectedInputFileName,
      expectedInputSHA256: configuration.inputSHA256
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
      lockAcquisitionID: lockAcquisitionID
    )
  }
}

/// Issue-118 owns the frozen whole-attempt replacement allowlist. Runtime failure causes are only
/// descriptive; this policy is the sole place that turns one into protocol eligibility and a
/// persisted reason string.
enum EvaluationAttemptFailurePolicy {
  static func replacementReason(for cause: AttemptFailureCause?) -> String? {
    switch cause {
    case .transportFailure:
      return "transport_failure"
    case .credentialRefreshExhausted:
      return "credential_refresh_exhausted"
    case .deadline:
      return "deadline"
    case .processInterruption:
      return "process_interruption"
    case .partialStreamWithoutCompletedTerminal:
      return "partial_stream_without_completed_terminal"
    case .credentialRefreshCompleted, .credentialStateUnavailable, .localOutputLimit,
      .modelIdentityMismatch, .none:
      return nil
    }
  }
}

private extension EvaluationAttemptRunner {
  struct MappedOutcome {
    let outcome: EvaluationAttemptOutcome
    let criticalCode: String?
    let rawOutput: String?
    let replacementDisposition: EvaluationReplacementDisposition
    let replacementReason: String
  }

  struct DegradationClassification {
    let outcome: EvaluationAttemptOutcome
    let criticalCode: String?
    let reason: String
  }

  static func verifiedTaskPrompt(
    configuration: EvaluationAttemptConfiguration
  ) throws -> String {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(
      at: URL(fileURLWithPath: configuration.taskPromptPath)
    )
    let observed = SHA256Digest.hex(data)
    guard observed == configuration.taskPromptSHA256 else {
      throw EvaluationAttemptError.taskPromptDigestMismatch(
        expected: configuration.taskPromptSHA256,
        observed: observed
      )
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw EvaluationAttemptError.taskPromptIsNotUTF8
    }
    return text
  }

  static func validate(
    roster: ProviderRoster,
    configuration: EvaluationAttemptConfiguration
  ) throws {
    guard roster.fallback == nil else {
      throw EvaluationAttemptError.fallbackRosterForbidden
    }
    let primary = roster.primary
    guard primary.configuredReference == configuration.providerReference else {
      throw EvaluationAttemptError.rosterProviderReferenceMismatch
    }
    guard primary.wireModel == configuration.wireModel else {
      throw EvaluationAttemptError.rosterWireModelMismatch
    }
    guard primary.costPolicy == .includedPlan else {
      throw EvaluationAttemptError.rosterCostPolicyMismatch
    }
    guard primary.reservationPolicy == .chatGPTReplayState else {
      throw EvaluationAttemptError.rosterReservationPolicyMismatch
    }
  }

  static func validateProductionPrompts(_ provenance: EvaluationFrozenProvenance) throws {
    let systemDigest = SHA256Digest.hex(Data(SystemPrompt.minimal.utf8))
    let proactiveDigest = SHA256Digest.hex(Data(SystemPrompt.proactive.utf8))
    guard systemDigest == provenance.systemPromptSHA256 else {
      throw EvaluationAttemptError.systemPromptDigestMismatch
    }
    guard proactiveDigest == provenance.proactiveSystemPromptSHA256 else {
      throw EvaluationAttemptError.proactiveSystemPromptDigestMismatch
    }
  }

  static func buildContext(
    configuration: EvaluationAttemptConfiguration,
    taskPrompt: String,
    sessionID: Int64,
    dispatcher: EvaluationToolDispatcher
  ) throws -> BuildResult {
    guard let fixedDate = configuration.fixedDate else {
      throw EvaluationConfigurationError.invalidFixedTimestamp(configuration.fixedTimestamp)
    }
    let builder = EvaluationRuntimeContextFactory.makeBuilder(
      workspaceRootURL: configuration.workspaceRootURL,
      providerReference: configuration.providerReference,
      wireModel: configuration.wireModel,
      toolDefinitions: dispatcher.definitions,
      budget: EvaluationRuntimeContextFactory.attemptBudget(
        toolDefinitions: dispatcher.definitions
      ),
      now: { fixedDate }
    )
    let snapshot = SessionContextSnapshot(
      history: [
        StoredMessage(
          role: .user,
          content: taskPrompt,
          provenance: .trusted
        )
      ],
      historyMessageIds: [1],
      windowStartMessageId: nil,
      isTainted: false,
      hasPrivateData: false
    )
    return try builder.assemble(snapshot: snapshot, sessionId: sessionID, origin: .scheduled)
  }

  // Exhaustive terminal mapping stays in one switch so a new `TurnResult` cannot bypass protocol
  // classification through a helper default.
  // swiftlint:disable:next function_body_length
  static func map(
    outcome: TurnOutcome,
    tools: [EvaluationToolRecord],
    http: EvaluationHTTPSnapshot,
    expectedInputFileName: String,
    expectedInputSHA256: String
  ) -> MappedOutcome {
    if let integrityFailure = http.integrityFailures.first {
      let modelMismatch = integrityFailure == "wire_model_mismatch"
      return MappedOutcome(
        outcome: modelMismatch ? .modelIdentityMismatch : .harnessFailure,
        criticalCode: integrityFailure,
        rawOutput: nil,
        replacementDisposition: .ineligible,
        replacementReason: modelMismatch ? "model_identity_mismatch" : "harness_integrity_failure"
      )
    }
    let toolViolation = EvaluationToolContract.violation(
      in: tools,
      expectedPath: expectedInputFileName
    )
    let completedContent: String?
    if case .completed(let content, _, _) = outcome.result {
      completedContent = content
    } else {
      completedContent = nil
    }
    let toolViolationIsBackedByAnObservedTool = tools.isEmpty == false
    let toolViolationIsTerminal =
      toolViolationIsBackedByAnObservedTool
      || completedContent != nil
      || http.responsesSends.count == PageEvaluationContract.maximumResponsesSendsPerAttempt
    if let toolViolation, toolViolationIsTerminal {
      return MappedOutcome(
        outcome: .toolContractFailure,
        criticalCode: toolViolation.rawValue,
        rawOutput: completedContent,
        replacementDisposition: .ineligible,
        replacementReason: "task_contract_failure"
      )
    }
    let hasUnexpectedSecondSend =
      http.responsesSends.count == PageEvaluationContract.maximumResponsesSendsPerAttempt
      && (http.responsesSends[0].untrustedPayloadSHA256 != nil
        || http.responsesSends[1].untrustedPayloadSHA256 != expectedInputSHA256)
    if hasUnexpectedSecondSend {
      return MappedOutcome(
        outcome: .harnessFailure,
        criticalCode: "untrusted_payload_digest_mismatch",
        rawOutput: nil,
        replacementDisposition: .ineligible,
        replacementReason: "harness_integrity_failure"
      )
    }

    switch outcome.result {
    case .completed(let content, _, _):
      return MappedOutcome(
        outcome: .completed,
        criticalCode: nil,
        rawOutput: content,
        replacementDisposition: .ineligible,
        replacementReason: "scorable_output_exists"
      )
    case .degraded(let kind, _):
      return map(
        degradation: kind,
        diagnostics: outcome.attemptDiagnostics
      )
    case .budgetStopped(let cap) where cap == "per-run tool-call" || cap == "per-run turn":
      return MappedOutcome(
        outcome: .budgetStopped,
        criticalCode: "tool_budget_stop",
        rawOutput: nil,
        replacementDisposition: .ineligible,
        replacementReason: "budget_or_tool_deviation"
      )
    case .budgetStopped(let cap) where EvaluationSendBudgetSnapshot.isControllerAdmissionCap(cap):
      return MappedOutcome(
        outcome: .budgetStopped,
        criticalCode: nil,
        rawOutput: nil,
        replacementDisposition: .ineligible,
        replacementReason: cap
      )
    case .budgetStopped(let cap):
      return MappedOutcome(
        outcome: .harnessFailure,
        criticalCode: cap,
        rawOutput: nil,
        replacementDisposition: .ineligible,
        replacementReason: "preflight_budget_exhausted"
      )
    case .suspended:
      return MappedOutcome(
        outcome: .toolContractFailure,
        criticalCode: EvaluationToolViolation.unexpectedSuspension.rawValue,
        rawOutput: nil,
        replacementDisposition: .ineligible,
        replacementReason: "task_contract_failure"
      )
    }
  }

  static func map(
    degradation: DegradationKind,
    diagnostics: AttemptDiagnostics
  ) -> MappedOutcome {
    let replacementReason = EvaluationAttemptFailurePolicy.replacementReason(
      for: diagnostics.failureCause
    )
    let replacementDisposition: EvaluationReplacementDisposition =
      replacementReason == nil ? .ineligible : .eligible
    let classification: DegradationClassification
    switch diagnostics.failureCause {
    case .credentialRefreshCompleted:
      classification = DegradationClassification(
        outcome: .providerFailure,
        criticalCode: nil,
        reason: "credential_refresh_completed"
      )
    case .credentialStateUnavailable:
      classification = DegradationClassification(
        outcome: .providerFailure,
        criticalCode: nil,
        reason: "credential_state_unavailable"
      )
    case .localOutputLimit:
      classification = DegradationClassification(
        outcome: .localOutputLimit,
        criticalCode: "local_output_limit",
        reason: "local_output_limit"
      )
    case .modelIdentityMismatch:
      classification = DegradationClassification(
        outcome: .modelIdentityMismatch,
        criticalCode: "model_identity_mismatch",
        reason: "model_identity_mismatch"
      )
    default:
      classification = degradationMapping(degradation)
    }
    return MappedOutcome(
      outcome: classification.outcome,
      criticalCode: classification.criticalCode,
      rawOutput: nil,
      replacementDisposition: replacementDisposition,
      replacementReason: replacementReason ?? classification.reason
    )
  }

  static func degradationMapping(
    _ degradation: DegradationKind
  ) -> DegradationClassification {
    switch degradation {
    case .authenticationRequired:
      return DegradationClassification(
        outcome: .authenticationRequired,
        criticalCode: nil,
        reason: "authentication"
      )
    case .accessDenied:
      return DegradationClassification(outcome: .accessDenied, criticalCode: nil, reason: "access")
    case .quotaLimited:
      return DegradationClassification(outcome: .quotaLimited, criticalCode: nil, reason: "quota")
    case .invalidProviderState:
      return DegradationClassification(
        outcome: .invalidProviderState,
        criticalCode: "invalid_provider_state",
        reason: "invalid_provider_state"
      )
    case .providerUnavailable, .outputTruncated, .contextUnavailable, .accountingFailed:
      return DegradationClassification(
        outcome: .providerFailure,
        criticalCode: nil,
        reason: "provider_terminal"
      )
    case .visionUnsupported:
      return DegradationClassification(
        outcome: .providerFailure,
        criticalCode: "vision_unsupported",
        reason: "vision_unsupported"
      )
    }
  }

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

enum EvaluationAttemptError: Error, Sendable, Equatable {
  case taskPromptDigestMismatch(expected: String, observed: String)
  case taskPromptIsNotUTF8
  case policyMismatch(expected: String, observed: String)
  case fallbackRosterForbidden
  case rosterProviderReferenceMismatch
  case rosterWireModelMismatch
  case rosterCostPolicyMismatch
  case rosterReservationPolicyMismatch
  case systemPromptDigestMismatch
  case proactiveSystemPromptDigestMismatch
}
