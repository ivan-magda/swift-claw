import ClawAgent
import ClawCore

extension EvaluationAttemptRunner {
  struct MappedOutcome {
    let outcome: EvaluationAttemptOutcome
    let criticalCode: String?
    let rawOutput: String?
    let replacementDisposition: EvaluationReplacementDisposition
    let replacementReason: String
  }

  // Exhaustive terminal mapping stays in one switch so a new `TurnResult` cannot bypass protocol
  // classification through a helper default.
  // swiftlint:disable:next function_body_length function_parameter_count
  static func map(
    outcome: TurnOutcome,
    tools: [EvaluationToolRecord],
    http: EvaluationHTTPSnapshot,
    expectedInputFileName: String,
    expectedInputSHA256: String,
    usesLearningProfile: Bool,
    learningCarrierVerified: Bool
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
      usesLearningProfile == false
      && http.responsesSends.count == PageEvaluationContract.maximumResponsesSendsPerAttempt
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
    if learningCarrierVerified == false {
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

  static func learningCarrierVerified(
    configuration: EvaluationAttemptConfiguration,
    http: EvaluationHTTPSnapshot,
    records: [EvaluationLabeledFenceRecord]
  ) -> Bool {
    guard configuration.executionProfile == .scheduledLearningV1 else {
      return true
    }
    let lessonSetDigest = configuration.lessonSetDigest
    guard http.responsesSends.isEmpty == false else {
      return false
    }
    let firstLessons = records.filter { record in
      record.sequence == 1 && record.label == "scheduled_learning_lessons"
    }
    let firstFileReads = records.filter { record in
      record.sequence == 1 && record.label == EvaluationToolContract.requiredToolName
    }
    guard
      firstLessons.count == 1,
      firstLessons[0].payloadSHA256 == lessonSetDigest,
      firstFileReads.isEmpty
    else {
      return false
    }
    guard http.responsesSends.count > 1 else {
      return true
    }
    let secondLessons = records.filter { record in
      record.sequence == 2 && record.label == "scheduled_learning_lessons"
    }
    let secondFileReads = records.filter { record in
      record.sequence == 2 && record.label == EvaluationToolContract.requiredToolName
    }
    return secondLessons.count == 1
      && secondLessons[0].payloadSHA256 == lessonSetDigest
      && secondFileReads.count == 1
      && secondFileReads[0].payloadSHA256 == configuration.inputSHA256
  }
}

// MARK: - Degradation Classification

private extension EvaluationAttemptRunner {
  struct DegradationClassification {
    let outcome: EvaluationAttemptOutcome
    let criticalCode: String?
    let reason: String
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
