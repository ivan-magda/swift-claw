import ClawAgent
import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

func startEvaluationAttemptProgress(
  configuration: EvaluationAttemptConfiguration,
  configurationURL: URL,
  freezeInputs: EvaluationFreezeInputs,
  budget: EvaluationSendBudgetSnapshot,
  journalName: String
) throws -> (
  invocation: EvaluationWorkerInvocation,
  recorder: EvaluationAttemptProgressRecorder
) {
  let journal = try EvaluationControllerJournal.startNew(
    evaluationRoot: configuration.evaluationRootURL,
    manifestSHA256: configuration.approval.manifestSHA256,
    freezeCommit: configuration.provenance.freezeCommit,
    fixedTimestamp: configuration.fixedTimestamp,
    journalName: journalName
  )
  let written = try EvaluationController.writeInvocation(
    kind: .attempt,
    configurationPath: configurationURL.path,
    freeze: freezeInputs,
    budget: budget,
    evaluationRoot: configuration.evaluationRootURL,
    journal: journal,
    attemptIDs: [configuration.attemptID],
    maximumResponsesSends: PageEvaluationContract.maximumResponsesSendsPerAttempt
  )
  let invocation = try EvaluationJSONFile.decode(
    EvaluationWorkerInvocation.self,
    from: URL(fileURLWithPath: written.path)
  )
  return (
    invocation,
    try EvaluationAttemptProgressRecorder.start(
      invocation: invocation,
      configurations: [configuration]
    )
  )
}

func publishEvaluationAttemptProgress(
  invocation: EvaluationWorkerInvocation,
  configurations: [EvaluationAttemptConfiguration],
  results: [EvaluationAttemptResult]
) throws {
  guard configurations.count == results.count else {
    throw EvaluationPagePipelineError.invalidBatch("test_progress_result_count")
  }
  let entries = try zip(configurations, results).map { configuration, result in
    EvaluationAttemptProgressEntry(
      attemptID: configuration.attemptID,
      configurationSHA256: try EvaluationAttemptProgressRecord.configurationSHA256(configuration),
      responsesRequests: result.http.responsesSends,
      provenNotStartedResponsesSends: result.http.provenNotStartedResponsesSends,
      credentialHTTPCalls: result.http.credentialHTTPCalls,
      fileReads: EvaluationToolContract.observedFileReads(
        in: result.tools,
        expectedPath: configuration.expectedInputFileName
      ),
      accountedTokens: result.accountedTokens,
      usage: result.usage
    )
  }
  let record = EvaluationAttemptProgressRecord(
    schemaVersion: PageEvaluationContract.schemaVersion,
    invocationID: invocation.invocationID,
    invocationConfigurationSHA256: invocation.configurationSHA256,
    manifestSHA256: try #require(configurations.first).approval.manifestSHA256,
    attempts: entries
  )
  try record.validate(
    invocationID: invocation.invocationID,
    invocationConfigurationSHA256: invocation.configurationSHA256,
    configurations: configurations
  )
  try EvaluationDurablePublication.publishExclusive(
    EvaluationCanonicalJSON.data(encoding: record),
    to: EvaluationAttemptProgressRecorder.url(
      invocationID: invocation.invocationID,
      configurations: configurations
    )
  )
}

func makeEvaluationReplacement(
  of original: EvaluationAttemptConfiguration,
  configurationDirectory: URL
) throws -> (configuration: EvaluationAttemptConfiguration, configurationURL: URL) {
  let attemptID = "\(original.attemptID)-r1"
  let resultURL = original.resultURL.deletingLastPathComponent()
    .appendingPathComponent("\(attemptID).json", isDirectory: false)
  let encoded = try EvaluationCanonicalJSON.data(encoding: original)
  var object = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
  )
  object["attempt_id"] = attemptID
  object["replacement_of_attempt_id"] = original.attemptID
  object["replacement_ordinal"] = 1
  object["result_path"] = resultURL.path
  let configurationURL = configurationDirectory.appendingPathComponent("\(attemptID).json")
  try EvaluationDurablePublication.publish(
    EvaluationCanonicalJSON.data(fromJSONObject: object),
    to: configurationURL
  )
  return (
    try EvaluationJSONFile.decode(EvaluationAttemptConfiguration.self, from: configurationURL),
    configurationURL
  )
}
