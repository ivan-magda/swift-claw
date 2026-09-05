import ClawAgent
import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

func makeEvaluationResult(
  configuration: EvaluationAttemptConfiguration,
  replacementDisposition: EvaluationReplacementDisposition,
  replacementReason: String? = nil,
  rawOutput: String? = nil,
  workspace: EvaluationWorkspaceMaterialization? = nil,
  processUUID: UUID = UUID(),
  processID: Int32 = 1,
  sessionID: Int64 = 3,
  responsesSends: [EvaluationResponsesSend] = [],
  tools: [EvaluationToolRecord] = [],
  audit: [EvaluationAuditRecord] = [],
  accountedTokens: Int = 0
) -> EvaluationAttemptResult {
  let effectiveSends =
    responsesSends.isEmpty && accountedTokens > 0
    ? [makeEvaluationResponsesSend(sequence: 1)] : responsesSends
  let usage: [EvaluationUsageRecord] =
    accountedTokens > 0
    ? [
      EvaluationUsageRecord(
        ProviderUsage(
          providerCallID: ProviderCallID(rawValue: "fixture-accounting"),
          runId: 2,
          sessionId: sessionID,
          model: PageEvaluationContract.wireModel,
          promptTokens: accountedTokens,
          completionTokens: 0,
          costUSD: 0,
          costSource: .providerReturned,
          isEstimated: false,
          ts: Date(timeIntervalSince1970: 0)
        )
      )
    ] : []
  return EvaluationAttemptResult(
    configuration: configuration,
    processUUID: processUUID,
    processID: processID,
    runID: 2,
    sessionID: sessionID,
    startedAt: "2026-08-26T00:00:00Z",
    finishedAt: "2026-08-26T00:00:01Z",
    durationMilliseconds: 1_000,
    policyVersion: configuration.expectedPolicyVersion,
    outcome: replacementDisposition == .eligible ? .providerFailure : .completed,
    criticalCode: nil,
    rawOutput: replacementDisposition == .eligible
      ? nil : (rawOutput ?? #"{"schema_version":1}"#),
    modelObservations: [],
    http: EvaluationHTTPSnapshot(
      responsesSends: effectiveSends,
      credentialHTTPCalls: 0,
      integrityFailures: []
    ),
    outputCounts: AttemptOutputCounts(utf8Bytes: 0, graphemes: 0, limitExceeded: false),
    tools: tools,
    audit: audit,
    usage: usage,
    accountedTokens: accountedTokens,
    replacementDisposition: replacementDisposition,
    replacementReason: replacementReason
      ?? (replacementDisposition == .eligible ? "transport_failure" : "scorable_output_exists"),
    workspace: workspace
      ?? EvaluationWorkspaceMaterialization(
        workspaceWasEmptyAtStart: true,
        inputWasRegenerated: true,
        inputPath: configuration.workspaceRootURL.appendingPathComponent("input.json").path,
        inputSHA256: configuration.inputSHA256,
        inputByteCount: 1,
        sourceArtifactPath: configuration.sourceArtifactPath,
        sourceSHA256: configuration.sourceSHA256,
        taskID: configuration.taskID,
        lessonSource: configuration.lessonSource,
        lessonSetPath: nil,
        lessonSetDigest: configuration.lessonSetDigest,
        lessonSetID: "empty",
        lessonIDs: [],
        carrierReceipt: EvaluationCarrierReceipt(
          sourceSHA256: configuration.sourceSHA256,
          taskID: configuration.taskID,
          lessonSource: configuration.lessonSource,
          lessonSetSHA256: configuration.lessonSetDigest,
          lessonSetID: "empty",
          lessonIDs: [],
          inputSHA256: configuration.inputSHA256
        ),
        carrierReceiptSHA256: String(repeating: "c", count: 64)
      ),
    lockAcquisitionID: UUID()
  )
}

func makeEvaluationResponsesSend(
  sequence: Int,
  requestedModel: String = PageEvaluationContract.wireModel,
  bodySHA256: String = String(repeating: "d", count: 64),
  normalizedStructureSHA256: String? = nil,
  untrustedPayloadSHA256: String? = nil
) -> EvaluationResponsesSend {
  EvaluationResponsesSend(
    sequence: sequence,
    requestedModel: requestedModel,
    bodyByteCount: 1,
    bodySHA256: bodySHA256,
    normalizedStructureSHA256: normalizedStructureSHA256 ?? bodySHA256,
    untrustedFencePresent: untrustedPayloadSHA256 != nil,
    untrustedPayloadSHA256: untrustedPayloadSHA256
  )
}

func makeCanaryEvidenceResult(
  configuration: EvaluationAttemptConfiguration,
  processUUID: UUID,
  sessionID: Int64,
  lessonSetID: String,
  lessonIDs: [String],
  outcome: EvaluationAttemptOutcome = .completed,
  requestedModel: String = PageEvaluationContract.wireModel,
  untrustedFencePresent: Bool = true,
  tools: [EvaluationToolRecord] = [
    EvaluationToolRecord(
      name: EvaluationToolContract.requiredToolName,
      path: PageEvaluationContract.inputFileName,
      status: EvaluationToolContract.succeededStatus
    )
  ],
  inputWasRegenerated: Bool = true,
  workspaceWasEmptyAtStart: Bool = true,
  policyVersion: String? = nil,
  lockAcquisitionID: UUID? = nil,
  reportedTokensPerSend: Int = 0
) throws -> EvaluationAttemptResult {
  let carrier = EvaluationCarrierReceipt(
    sourceSHA256: configuration.sourceSHA256,
    taskID: configuration.taskID,
    lessonSource: configuration.lessonSource,
    lessonSetSHA256: configuration.lessonSetDigest,
    lessonSetID: lessonSetID,
    lessonIDs: lessonIDs,
    inputSHA256: configuration.inputSHA256
  )
  let sends = [
    makeEvaluationResponsesSend(
      sequence: 1,
      requestedModel: requestedModel,
      untrustedPayloadSHA256: nil
    ),
    makeEvaluationResponsesSend(
      sequence: 2,
      requestedModel: requestedModel,
      untrustedPayloadSHA256: untrustedFencePresent ? configuration.inputSHA256 : nil
    ),
  ]
  let usage = sends.indices.map { index in
    EvaluationUsageRecord(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "canary-\(index + 1)"),
        runId: 2,
        sessionId: sessionID,
        model: requestedModel,
        promptTokens: reportedTokensPerSend,
        completionTokens: 0,
        costUSD: 0,
        costSource: .providerReturned,
        isEstimated: false,
        ts: Date(timeIntervalSince1970: 0)
      )
    )
  }
  return EvaluationAttemptResult(
    configuration: configuration,
    processUUID: processUUID,
    processID: 1,
    runID: 2,
    sessionID: sessionID,
    startedAt: "2026-08-26T00:00:00Z",
    finishedAt: "2026-08-26T00:00:01Z",
    durationMilliseconds: 1_000,
    policyVersion: policyVersion ?? configuration.expectedPolicyVersion,
    outcome: outcome,
    criticalCode: nil,
    rawOutput: outcome == .completed ? #"{"schema_version":1}"# : nil,
    modelObservations: [
      ModelRoundTripObservation(outboundModel: requestedModel, terminalModel: requestedModel),
      ModelRoundTripObservation(outboundModel: requestedModel, terminalModel: requestedModel),
    ],
    http: EvaluationHTTPSnapshot(
      responsesSends: sends,
      credentialHTTPCalls: 0,
      integrityFailures: []
    ),
    outputCounts: AttemptOutputCounts(utf8Bytes: 0, graphemes: 0, limitExceeded: false),
    tools: tools,
    usage: usage,
    accountedTokens: SaturatingArithmetic.product(sends.count, reportedTokensPerSend),
    replacementDisposition: .ineligible,
    replacementReason: "scorable_output_exists",
    workspace: EvaluationWorkspaceMaterialization(
      workspaceWasEmptyAtStart: workspaceWasEmptyAtStart,
      inputWasRegenerated: inputWasRegenerated,
      inputPath: configuration.workspaceRootURL.appendingPathComponent("input.json").path,
      inputSHA256: configuration.inputSHA256,
      inputByteCount: 1,
      sourceArtifactPath: configuration.sourceArtifactPath,
      sourceSHA256: configuration.sourceSHA256,
      taskID: configuration.taskID,
      lessonSource: configuration.lessonSource,
      lessonSetPath: nil,
      lessonSetDigest: configuration.lessonSetDigest,
      lessonSetID: lessonSetID,
      lessonIDs: lessonIDs,
      carrierReceipt: carrier,
      carrierReceiptSHA256: SHA256Digest.hex(
        try EvaluationCanonicalJSON.data(encoding: carrier)
      )
    ),
    lockAcquisitionID: lockAcquisitionID ?? processUUID
  )
}
