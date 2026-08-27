import ClawAgent
import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

func makeEvaluationTestRoot() throws -> URL {
  let root = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
  )
  .appendingPathComponent(".build", isDirectory: true)
  .appendingPathComponent("swift-claw-evaluation-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

func makeEvaluationConfiguration(
  root: URL,
  attemptID: String = "attempt-1",
  fixtureID: String = "pc-development-01",
  split: String = "development",
  expectedPolicyVersion: String? = nil,
  approvalURL: String =
    "https://github.com/ivan-magda/swift-claw/issues/118#issuecomment-5423356186",
  stage: String = "development",
  frozenOrderIndex: Int = 0,
  frozenOrderKey: String = String(repeating: "d", count: 64),
  condition: EvaluationCondition = .clean,
  lessonSource: EvaluationLessonSource = .clean,
  activeLessons: [String: Any]? = nil,
  publishLessonAsActive: Bool = false,
  sourceArtifactPath: String? = nil,
  lessonArtifactPath: String? = nil,
  replacementOfAttemptID: String? = nil,
  replacementOrdinal: Int = 0
) throws -> (configuration: EvaluationAttemptConfiguration, configurationURL: URL) {
  let artifacts = root.appendingPathComponent("artifacts")
  let evaluation = root.appendingPathComponent("evaluation")
  let results = evaluation.appendingPathComponent("results")
  try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)

  let sourceURL =
    sourceArtifactPath.map(URL.init(fileURLWithPath:))
    ?? artifacts.appendingPathComponent("\(attemptID)-source.json")
  let promptURL = artifacts.appendingPathComponent("task.md")
  let source = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "family_id": "test-family",
    "fixture_id": fixtureID,
    "schema_version": 1,
    "split": split,
    "task": [:],
    "task_id": "page-000000000001",
  ])
  let emptyLessonObject: [String: Any] = [
    "lesson_set_id": "empty",
    "lessons": [],
    "schema_version": 1,
  ]
  let selectedLessons = activeLessons ?? emptyLessonObject
  let lessonData = try EvaluationCanonicalJSON.data(fromJSONObject: selectedLessons)
  let lessonURL =
    lessonArtifactPath.map(URL.init(fileURLWithPath:))
    ?? artifacts.appendingPathComponent("\(attemptID)-lessons.json")
  if lessonSource == .artifact, lessonArtifactPath == nil {
    try lessonData.write(to: lessonURL)
  }
  let input = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "active_lessons": selectedLessons,
    "schema_version": 1,
    "task": [:],
    "task_id": "page-000000000001",
  ])
  let prompt = Data("Read input.json exactly once and return one JSON object.".utf8)
  if sourceArtifactPath == nil {
    try source.write(to: sourceURL)
  }
  try prompt.write(to: promptURL)

  let digest = String(repeating: "a", count: 64)
  let approval = EvaluationApprovalBinding(
    commentID: 5_423_356_186,
    commentNodeID: "IC_kwDO-test",
    authorLogin: "ivan-magda",
    authorID: 1,
    authorNodeID: "MDQ6VXNlcjE=",
    createdAt: "2026-08-26T00:00:00Z",
    updatedAt: "2026-08-26T00:00:00Z",
    manifestSHA256: digest,
    approvedManifestSHA256: digest,
    approvalCommentURL: approvalURL,
    approvalBodySHA256: digest
  )
  let provenance = EvaluationFrozenProvenance(
    freezeCommit: String(repeating: "b", count: 40),
    executableSHA256: digest,
    runtimeSourcesSHA256: digest,
    harnessSourcesSHA256: digest,
    dependenciesSHA256: digest,
    configurationSHA256: digest,
    modelSHA256: digest,
    retrySHA256: digest,
    outputSHA256: digest,
    promptsSHA256: digest,
    schemasSHA256: digest,
    scorerSHA256: digest,
    splitsSHA256: digest,
    runOrderSHA256: digest,
    systemPromptSHA256: SHA256Digest.hex(Data(SystemPrompt.minimal.utf8)),
    proactiveSystemPromptSHA256: SHA256Digest.hex(Data(SystemPrompt.proactive.utf8))
  )
  let resultURL = results.appendingPathComponent("\(attemptID).json")
  let configuration = EvaluationAttemptConfiguration(
    attemptID: attemptID,
    fixtureID: fixtureID,
    taskID: "page-000000000001",
    split: split,
    stage: stage,
    frozenOrderIndex: frozenOrderIndex,
    frozenOrderKey: frozenOrderKey,
    replicate: 1,
    condition: condition,
    evaluationRoot: evaluation.path,
    sourceArtifactPath: sourceURL.path,
    sourceSHA256: SHA256Digest.hex(source),
    inputSHA256: SHA256Digest.hex(input),
    lessonSource: lessonSource,
    lessonArtifactPath: lessonSource == .artifact ? lessonURL.path : nil,
    publishLessonAsActive: publishLessonAsActive,
    taskPromptPath: promptURL.path,
    taskPromptSHA256: SHA256Digest.hex(prompt),
    resultPath: resultURL.path,
    fixedTimestamp: "2026-08-26T00:00:00Z",
    protocolSHA256: digest,
    lessonSetDigest: SHA256Digest.hex(lessonData),
    expectedPolicyVersion: expectedPolicyVersion
      ?? EvaluationPolicyInspector.policyVersion(evaluationRootURL: evaluation),
    approval: approval,
    provenance: provenance,
    replacementOfAttemptID: replacementOfAttemptID,
    replacementOrdinal: replacementOrdinal
  )
  let configurationURL = artifacts.appendingPathComponent("\(attemptID)-configuration.json")
  try EvaluationJSONFile.write(configuration, to: configurationURL)
  return (configuration, configurationURL)
}

func makeEvaluationLessonReloadConfigurations(
  root: URL
) throws -> (
  artifact: EvaluationAttemptConfiguration,
  durable: EvaluationAttemptConfiguration
) {
  let lessons: [String: Any] = [
    "lesson_set_id": "candidate",
    "lessons": [
      [
        "lesson_id": "ignore-counters",
        "target_class": "noise.volatile_value",
        "text": "Treat rotating counters as cosmetic unless they change a task fact.",
      ]
    ],
    "schema_version": 1,
  ]
  return try (
    makeEvaluationConfiguration(
      root: root,
      attemptID: "process-a-nonempty",
      stage: "canary",
      condition: .canary,
      lessonSource: .artifact,
      activeLessons: lessons,
      publishLessonAsActive: true
    ).configuration,
    makeEvaluationConfiguration(
      root: root,
      attemptID: "process-b-nonempty",
      stage: "canary",
      condition: .canary,
      lessonSource: .durableActive,
      activeLessons: lessons
    ).configuration
  )
}

func makeEvaluationResult(
  configuration: EvaluationAttemptConfiguration,
  replacementDisposition: EvaluationReplacementDisposition,
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
    rawOutput: replacementDisposition == .eligible ? nil : #"{"schema_version":1}"#,
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
    replacementReason: replacementDisposition == .eligible
      ? "transport_failure" : "scorable_output_exists",
    workspace: EvaluationWorkspaceMaterialization(
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

func makeEvaluationFreeze(
  root: URL,
  configurations: [EvaluationAttemptConfiguration]
) throws -> (inputs: EvaluationFreezeInputs, context: EvaluationFreezeContext, executable: URL) {
  let repository = root.standardizedFileURL
  let configDirectory = repository.appendingPathComponent("config")
  let runtimeURL = configDirectory.appendingPathComponent("runtime.json")
  let executable = repository.appendingPathComponent("bin/claw-eval")
  let manifestURL = configDirectory.appendingPathComponent("manifest.json")
  let approvalURL = configDirectory.appendingPathComponent("approval.json")
  let approvalBodyURL = configDirectory.appendingPathComponent("approval-body.txt")
  let receiptURL = configurations[0].evaluationRootURL.appendingPathComponent("freeze-receipt.json")
  try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

  let frozenRuntimeURL = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
  ).appendingPathComponent("experiments/scheduled-task-learning/page-change/config/runtime.json")
  var runtimeObject = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: frozenRuntimeURL)) as? [String: Any]
  )
  runtimeObject["evaluation_root"] = configurations[0].evaluationRoot
  runtimeObject["expected_policy_version"] = configurations[0].expectedPolicyVersion
  runtimeObject["task_prompt_path"] = "artifacts/task.md"
  runtimeObject["executable_path"] = "bin/claw-eval"
  runtimeObject["freeze_verifier_path"] = "tools/freeze.py"
  try EvaluationCanonicalJSON.data(fromJSONObject: runtimeObject).write(to: runtimeURL)
  let runtime = try EvaluationRuntimeConfiguration.load(from: runtimeURL)
  let digest = String(repeating: "a", count: 64)
  let runtimeData = try Data(contentsOf: runtimeURL)
  let promptData = try Data(contentsOf: URL(fileURLWithPath: configurations[0].taskPromptPath))
  let artifacts = try configurations.map { configuration in
    let url = URL(fileURLWithPath: configuration.sourceArtifactPath)
    let data = try Data(contentsOf: url)
    return EvaluationManifestProtectedArtifact(
      path: testRelativePath(url, under: repository),
      bytes: data.count,
      sha256: SHA256Digest.hex(data)
    )
  }
  let lessonArtifacts = try configurations.compactMap {
    configuration -> EvaluationManifestProtectedArtifact? in
    guard let path = configuration.lessonArtifactPath else { return nil }
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return EvaluationManifestProtectedArtifact(
      path: testRelativePath(url, under: repository),
      bytes: data.count,
      sha256: SHA256Digest.hex(data)
    )
  }
  let runtimeArtifact = EvaluationManifestArtifact(
    role: "runtime",
    path: "config/runtime.json",
    bytes: runtimeData.count,
    sha256: SHA256Digest.hex(runtimeData)
  )
  let promptArtifact = EvaluationManifestArtifact(
    role: "task",
    path: "artifacts/task.md",
    bytes: promptData.count,
    sha256: SHA256Digest.hex(promptData)
  )
  let executableArtifact = EvaluationManifestArtifact(
    role: "executable",
    path: "bin/claw-eval",
    bytes: 1,
    sha256: digest
  )
  var categories: [String: EvaluationManifestCategory] = [:]
  for name in [
    "runtime_sources", "harness_sources", "dependencies", "configuration", "model", "retry",
    "output", "prompts", "schemas", "scorer", "splits", "run_order", "executable", "budget",
  ] {
    categories[name] = EvaluationManifestCategory(artifacts: [], sha256: digest)
  }
  categories["budget"] = EvaluationManifestCategory(
    artifacts: [],
    values: PageEvaluationContract.budgetManifestValues,
    sha256: digest
  )
  var configurationArtifacts = [runtimeArtifact]
  if configurations.first?.stage == "canary",
    let sourceConfiguration = configurations.first,
    let cleanConfiguration = configurations.first(where: { $0.lessonSource == .clean }),
    let nonemptyConfiguration = configurations.first(where: { $0.lessonSource == .artifact }),
    let nonemptyPath = nonemptyConfiguration.lessonArtifactPath
  {
    let cleanURL = configDirectory.appendingPathComponent("canary-clean-lessons.json")
    let canaryURL = configDirectory.appendingPathComponent("canary.json")
    let cleanData = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "schema_version": 1, "lesson_set_id": "empty", "lessons": [],
    ])
    try cleanData.write(to: cleanURL)
    let sourceURL = URL(fileURLWithPath: sourceConfiguration.sourceArtifactPath)
    let sourceData = try Data(contentsOf: sourceURL)
    let nonemptyURL = URL(fileURLWithPath: nonemptyPath)
    let nonemptyData = try Data(contentsOf: nonemptyURL)
    let sourceRecord = EvaluationManifestArtifact(
      role: "canary_base_task",
      path: testRelativePath(sourceURL, under: repository),
      bytes: sourceData.count,
      sha256: SHA256Digest.hex(sourceData)
    )
    let cleanRecord = EvaluationManifestArtifact(
      role: "canary_clean_lessons",
      path: testRelativePath(cleanURL, under: repository),
      bytes: cleanData.count,
      sha256: SHA256Digest.hex(cleanData)
    )
    let nonemptyRecord = EvaluationManifestArtifact(
      role: "canary_nonempty_lessons",
      path: testRelativePath(nonemptyURL, under: repository),
      bytes: nonemptyData.count,
      sha256: SHA256Digest.hex(nonemptyData)
    )
    let canaryData = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "schema_version": 1,
      "fixture_id": sourceConfiguration.fixtureID,
      "task_id": sourceConfiguration.taskID,
      "base_task": ["path": sourceRecord.path, "sha256": sourceRecord.sha256],
      "lesson_sets": [
        "clean": ["path": cleanRecord.path, "sha256": cleanRecord.sha256],
        "nonempty": ["path": nonemptyRecord.path, "sha256": nonemptyRecord.sha256],
      ],
      "expected_input_sha256": [
        "clean": cleanConfiguration.inputSHA256,
        "nonempty": nonemptyConfiguration.inputSHA256,
      ],
    ])
    try canaryData.write(to: canaryURL)
    configurationArtifacts += [
      EvaluationManifestArtifact(
        role: "canary",
        path: testRelativePath(canaryURL, under: repository),
        bytes: canaryData.count,
        sha256: SHA256Digest.hex(canaryData)
      ),
      sourceRecord,
      cleanRecord,
      nonemptyRecord,
    ]
  }
  categories["configuration"] = EvaluationManifestCategory(
    artifacts: configurationArtifacts,
    sha256: digest
  )
  categories["prompts"] = EvaluationManifestCategory(
    artifacts: [promptArtifact],
    sha256: digest
  )
  categories["executable"] = EvaluationManifestCategory(
    artifacts: [executableArtifact],
    sha256: digest
  )
  let manifest = EvaluationFreezeManifest(
    categories: categories,
    protectedArtifacts: Array(
      Dictionary(
        grouping: artifacts + lessonArtifacts
          + configurationArtifacts.map {
            EvaluationManifestProtectedArtifact(
              path: $0.path,
              bytes: $0.bytes,
              sha256: $0.sha256
            )
          },
        by: \.path
      ).values.compactMap(\.first)
    )
      + [
        EvaluationManifestProtectedArtifact(
          path: promptArtifact.path,
          bytes: promptArtifact.bytes,
          sha256: promptArtifact.sha256
        )
      ]
  )
  let approval = configurations[0].approval
  let receipt = EvaluationFreezeReceipt(
    schemaVersion: 1,
    status: "verified",
    verifiedAt: "2026-08-26T00:00:00Z",
    decision: "D6",
    experiment: "page-change",
    manifest: EvaluationFreezeReceipt.ManifestBinding(
      path: "config/manifest.json",
      sha256: approval.manifestSHA256
    ),
    verifier: EvaluationFreezeReceipt.FileBinding(
      path: "tools/freeze.py",
      bytes: 1,
      sha256: digest,
      gitMode: "100644",
      format: nil
    ),
    verifierModules: [
      EvaluationFreezeReceipt.FileBinding(
        path: "tools/freeze.py",
        bytes: 1,
        sha256: digest,
        gitMode: "100644",
        format: nil
      )
    ],
    freezeCommit: configurations[0].provenance.freezeCommit,
    comment: EvaluationFreezeReceipt.Comment(
      id: approval.commentID,
      nodeID: approval.commentNodeID,
      author: EvaluationFreezeReceipt.Author(
        login: approval.authorLogin,
        id: approval.authorID,
        nodeID: approval.authorNodeID
      ),
      createdAt: approval.createdAt,
      updatedAt: approval.updatedAt,
      bodySHA256: approval.approvalBodySHA256
    ),
    executable: EvaluationFreezeReceipt.FileBinding(
      path: executableArtifact.path,
      bytes: executableArtifact.bytes,
      sha256: digest,
      gitMode: "100755",
      format: "mach-o-arm64"
    )
  )
  let stages: [[String: Any]]
  if configurations.first?.stage == "canary" {
    stages = [
      [
        "name": "canary",
        "kind": "canary-events",
        "events": configurations.enumerated().map { index, configuration in
          [
            "kind": "attempt",
            "attempt_index": index + 1,
            "fixture_id": configuration.fixtureID,
            "task_id": configuration.taskID,
            "lesson_source": configuration.lessonSource.rawValue,
            "publish_active": configuration.publishLessonAsActive,
            "order_key": configuration.frozenOrderKey,
          ] as [String: Any]
        },
      ]
    ]
  } else {
    stages = [
      [
        "name": configurations.first?.stage ?? "development",
        "kind": "task-attempts",
        "attempts": configurations.enumerated().map { index, configuration in
          [
            "order_index": configuration.frozenOrderIndex,
            "block_index": 0,
            "attempt_order_key": configuration.frozenOrderKey,
            "block_order_key": String(repeating: "b", count: 64),
            "split": configuration.split,
            "fixture_id": configuration.fixtureID,
            "replicate_index": configuration.replicate,
            "condition": configuration.condition.runOrderValue,
            "sequence": index,
          ] as [String: Any]
        },
      ]
    ]
  }
  let order = try EvaluationCanonicalJSON.data(fromJSONObject: ["stages": stages])
  let context = EvaluationFreezeContext(
    repositoryRoot: repository.path,
    manifest: manifest,
    receipt: receipt,
    runtime: runtime,
    runOrderJSON: order
  )
  let inputs = EvaluationFreezeInputs(
    repositoryRoot: repository.path,
    manifestPath: manifestURL.path,
    manifestSHA256: approval.manifestSHA256,
    approvalRecordPath: approvalURL.path,
    approvalBodyPath: approvalBodyURL.path,
    runtimeConfigurationPath: runtimeURL.path,
    receiptPath: receiptURL.path
  )
  return (inputs, context, executable)
}

struct CanaryControllerFixture {
  let configurations: [EvaluationAttemptConfiguration]
  let inputs: EvaluationFreezeInputs
  let context: EvaluationFreezeContext
  let executable: URL
  let order: EvaluationPageRunOrder
  let paths: EvaluationController.PagePipelinePaths
  let factory: EvaluationPageConfigurationFactory
}

// swiftlint:disable:next function_body_length
func makeApprovedEvaluationRunOrderJSON(
  manifestSHA256: String,
  canaryProcesses suppliedCanaryProcesses: [EvaluationPageCanaryProcessSlot] = [],
  anchor: EvaluationAttemptConfiguration? = nil
) throws -> Data {
  let canaryProcesses =
    suppliedCanaryProcesses.isEmpty
    ? makeApprovedCanaryProcesses(anchor: anchor) : suppliedCanaryProcesses
  var sealedBlockKeys: [String: String] = [:]

  func taskStage(
    stage: EvaluationPageStage,
    fixtureCount: Int,
    conditions: [EvaluationCondition],
    counterbalancePhase: Int?
  ) -> [String: Any] {
    var attempts: [[String: Any]] = []
    var blockIndex = 0
    let split = stage.split.rawValue
    for fixtureIndex in 1...fixtureCount {
      let fixtureID = String(format: "pc-%@-%02d", split, fixtureIndex)
      for replicate in 1...PageEvaluationContract.replicateCount {
        let blockIdentity = "\(fixtureID):\(replicate)"
        let blockKey: String
        if stage == .sealedPostRestart {
          blockKey =
            sealedBlockKeys[blockIdentity]
            ?? SHA256Digest.hex(
              "block:\(EvaluationPageStage.sealedPreRestart.rawValue):\(blockIdentity)"
            )
        } else {
          blockKey = SHA256Digest.hex("block:\(stage.rawValue):\(blockIdentity)")
          if stage == .sealedPreRestart {
            sealedBlockKeys[blockIdentity] = blockKey
          }
        }
        var blockConditions = conditions
        if let counterbalancePhase,
          (blockIndex + counterbalancePhase).isMultiple(of: 2) == false
        {
          blockConditions.reverse()
        }
        for condition in blockConditions {
          let orderIndex = attempts.count
          let isAnchor =
            anchor?.stage == stage.rawValue
            && anchor?.fixtureID == fixtureID
            && anchor?.replicate == replicate
            && anchor?.condition == condition
          let lessonSource: EvaluationLessonSource
          switch condition {
          case .clean: lessonSource = .clean
          case .lessonConditioned: lessonSource = .artifact
          case .postRestartLessonConditioned: lessonSource = .durableActive
          case .synthesis, .canary: lessonSource = .clean
          }
          let orderKey: String
          if isAnchor, let anchor {
            orderKey = anchor.frozenOrderKey
          } else {
            orderKey = SHA256Digest.hex("attempt:\(stage.rawValue):\(orderIndex)")
          }
          attempts.append([
            "attempt_order_key": orderKey,
            "block_index": blockIndex,
            "block_order_key": blockKey,
            "condition": condition.runOrderValue,
            "conversation_policy": "fresh",
            "fixture_id": fixtureID,
            "lesson_source": lessonSource.rawValue,
            "order_index": orderIndex,
            "replicate_index": replicate,
            "split": split,
            "worker_process_key": SHA256Digest.hex("worker:\(stage.rawValue):\(orderIndex)"),
            "workspace_policy": "reset-to-exactly-input-json",
          ])
        }
        blockIndex += 1
      }
    }
    return [
      "attempts": attempts,
      "counterbalance_phase": counterbalancePhase.map { $0 as Any } ?? NSNull(),
      "kind": "task-attempts",
      "name": stage.rawValue,
      "split": split,
      "worker_process_policy": "fresh-os-process-per-attempt",
    ]
  }

  let canaryAttempts = canaryProcesses.flatMap(\.attempts)
  guard canaryAttempts.count == PageEvaluationContract.canaryPlannedAttempts else {
    throw EvaluationPagePipelineError.invalidRunOrder
  }
  let canaryEvents: [[String: Any]] = [
    approvedCanaryEvent(canaryAttempts[0]),
    approvedCanaryEvent(canaryAttempts[1]),
    [
      "barrier": "full-process-restart",
      "from_process": "A",
      "kind": "barrier",
      "order_key": SHA256Digest.hex("canary-restart-barrier"),
      "to_process": "B",
    ],
    approvedCanaryEvent(canaryAttempts[2]),
    approvedCanaryEvent(canaryAttempts[3]),
  ]
  let stages: [[String: Any]] = [
    [
      "attempts_per_worker_process": PageEvaluationContract.canaryAttemptsPerProcess,
      "events": canaryEvents,
      "kind": "canary-events",
      "name": EvaluationPageStage.canary.rawValue,
      "worker_process_count": PageEvaluationContract.canaryProcessCount,
    ],
    taskStage(
      stage: .development,
      fixtureCount: PageEvaluationContract.developmentFixtureCount,
      conditions: [.clean],
      counterbalancePhase: nil
    ),
    [
      "condition": EvaluationCondition.synthesis.runOrderValue,
      "kind": "synthesis-attempt",
      "name": EvaluationPageStage.synthesis.rawValue,
      "order_key": SHA256Digest.hex("synthesis-order"),
      "prompt_path": "prompts/synthesis.md",
      "worker_process_key": SHA256Digest.hex("synthesis-worker"),
      "worker_process_policy": "fresh-os-process",
    ],
    approvedBarrier(
      name: "lesson-freeze-barrier",
      value: "freeze-one-semantic-lesson-set-before-regression"
    ),
    taskStage(
      stage: .regression,
      fixtureCount: PageEvaluationContract.regressionFixtureCount,
      conditions: [.clean, .lessonConditioned],
      counterbalancePhase: 0
    ),
    approvedBarrier(
      name: "regression-unseal-barrier",
      value: "jointly-unseal-both-regression-conditions-and-apply-admission-gate"
    ),
    taskStage(
      stage: .sealedPreRestart,
      fixtureCount: PageEvaluationContract.sealedFixtureCount,
      conditions: [.clean, .lessonConditioned],
      counterbalancePhase: 0
    ),
    approvedBarrier(
      name: "sealed-full-process-restart-barrier",
      value: "publish-flush-exit-release-lock-and-start-new-os-process"
    ),
    taskStage(
      stage: .sealedPostRestart,
      fixtureCount: PageEvaluationContract.sealedFixtureCount,
      conditions: [.postRestartLessonConditioned],
      counterbalancePhase: nil
    ),
    approvedBarrier(
      name: "sealed-joint-unseal-barrier",
      value: "jointly-unseal-clean-lesson-and-post-restart-sealed-conditions"
    ),
  ]
  return try EvaluationCanonicalJSON.data(fromJSONObject: [
    "algorithm": "sha256-length-prefixed-counterbalanced-stage-order",
    "algorithm_version": 2,
    "manifest_sha256": manifestSHA256,
    "planned_attempts": [
      "canary": PageEvaluationContract.canaryPlannedAttempts,
      "page_synthesis": PageEvaluationContract.pageSynthesisPlannedAttempts,
      "page_task": PageEvaluationContract.pageTaskPlannedAttempts,
      "page_task_or_synthesis": PageEvaluationContract.pagePlannedAttempts,
    ],
    "schema_version": 2,
    "stages": stages,
  ])
}

private func makeApprovedCanaryProcesses(
  anchor: EvaluationAttemptConfiguration?
) -> [EvaluationPageCanaryProcessSlot] {
  let fixtureID = anchor?.fixtureID ?? "pc-development-01"
  let taskID = anchor?.taskID ?? "page-000000000001"
  let processKeys = [SHA256Digest.hex("canary-process-a"), SHA256Digest.hex("canary-process-b")]
  let cleanLessonPath = "config/canary-clean-lessons.json"
  let specifications: [(Int, String, String, String, EvaluationLessonSource, String?, Bool)] = [
    (1, "A", processKeys[0], "clean", EvaluationLessonSource.clean, cleanLessonPath, false),
    (
      2,
      "A",
      processKeys[0],
      "nonempty",
      EvaluationLessonSource.artifact,
      "config/canary-nonempty-lessons.json",
      true
    ),
    (3, "B", processKeys[1], "clean", EvaluationLessonSource.clean, cleanLessonPath, false),
    (4, "B", processKeys[1], "nonempty", EvaluationLessonSource.durableActive, nil, false),
  ]
  let attempts = specifications.map {
    index,
    process,
    processKey,
    condition,
    lessonSource,
    lessonPath,
    publish in
    EvaluationPageCanaryAttemptSlot(
      attemptIndex: index,
      fixtureID: fixtureID,
      taskID: taskID,
      process: process,
      workerProcessKey: processKey,
      condition: condition,
      lessonSource: lessonSource,
      lessonArtifactPath: lessonPath,
      publishActive: publish,
      sourcePath: "config/canary-base-task.json",
      configurationPath: "config/canary.json",
      orderKey: SHA256Digest.hex("canary-order-\(index)")
    )
  }
  return [
    EvaluationPageCanaryProcessSlot(
      process: "A",
      workerProcessKey: processKeys[0],
      attempts: Array(attempts.prefix(PageEvaluationContract.canaryAttemptsPerProcess))
    ),
    EvaluationPageCanaryProcessSlot(
      process: "B",
      workerProcessKey: processKeys[1],
      attempts: Array(attempts.suffix(PageEvaluationContract.canaryAttemptsPerProcess))
    ),
  ]
}

private func approvedCanaryEvent(_ slot: EvaluationPageCanaryAttemptSlot) -> [String: Any] {
  [
    "attempt_index": slot.attemptIndex,
    "condition": slot.condition,
    "configuration_path": slot.configurationPath,
    "fixture_id": slot.fixtureID,
    "kind": "attempt",
    "lesson_artifact_path": slot.lessonArtifactPath.map { $0 as Any } ?? NSNull(),
    "lesson_source": slot.lessonSource.rawValue,
    "order_key": slot.orderKey,
    "process": slot.process,
    "publish_active": slot.publishActive,
    "source_path": slot.sourcePath,
    "task_id": slot.taskID,
    "worker_process_key": slot.workerProcessKey,
  ]
}

private func approvedBarrier(name: String, value: String) -> [String: Any] {
  [
    "barrier": value,
    "kind": "barrier",
    "name": name,
    "order_key": SHA256Digest.hex("barrier:\(name)"),
  ]
}

func makeCanaryControllerFixture(root: URL) throws -> CanaryControllerFixture {
  let lessons = try makeEvaluationLessonReloadConfigurations(root: root)
  let configurations = try [
    makeEvaluationConfiguration(
      root: root,
      attemptID: "canary-a-clean",
      stage: EvaluationPageStage.canary.rawValue,
      condition: .canary
    ).configuration,
    lessons.artifact,
    makeEvaluationConfiguration(
      root: root,
      attemptID: "canary-b-clean",
      stage: EvaluationPageStage.canary.rawValue,
      condition: .canary
    ).configuration,
    lessons.durable,
  ]
  let frozen = try makeEvaluationFreeze(root: root, configurations: configurations)
  let digest = configurations[0].protocolSHA256
  let manifest = EvaluationFreezeManifest(
    schemaVersion: PageEvaluationContract.schemaVersion,
    decision: "D6",
    experiment: "page-change",
    protocolBinding: EvaluationManifestProtocolBinding(
      version: "0.2",
      path: "docs/research/118-validation-protocol.md",
      bytes: 1,
      sha256: digest
    ),
    categories: frozen.context.manifest.categories,
    protectedArtifacts: frozen.context.manifest.protectedArtifacts
  )
  let context = EvaluationFreezeContext(
    repositoryRoot: frozen.context.repositoryRoot,
    manifest: manifest,
    receipt: frozen.context.receipt,
    runtime: frozen.context.runtime,
    runOrderJSON: frozen.context.runOrderJSON
  )
  try EvaluationCanonicalJSON.data(fromJSONObject: [
    "comment": ["html_url": configurations[0].approval.approvalCommentURL]
  ]).write(to: URL(fileURLWithPath: frozen.inputs.approvalRecordPath))
  let source = try #require(
    manifest.artifact(role: "canary_base_task", category: "configuration")
  )
  let contract = try #require(manifest.artifact(role: "canary", category: "configuration"))
  let clean = try #require(
    manifest.artifact(role: "canary_clean_lessons", category: "configuration")
  )
  let nonempty = try #require(
    manifest.artifact(role: "canary_nonempty_lessons", category: "configuration")
  )
  let processAKey = SHA256Digest.hex("canary-process-a")
  let processBKey = SHA256Digest.hex("canary-process-b")
  func slot(
    index: Int,
    process: String,
    processKey: String,
    condition: String,
    lessonSource: EvaluationLessonSource,
    lessonPath: String?,
    publish: Bool
  ) -> EvaluationPageCanaryAttemptSlot {
    EvaluationPageCanaryAttemptSlot(
      attemptIndex: index,
      fixtureID: configurations[0].fixtureID,
      taskID: configurations[0].taskID,
      process: process,
      workerProcessKey: processKey,
      condition: condition,
      lessonSource: lessonSource,
      lessonArtifactPath: lessonPath,
      publishActive: publish,
      sourcePath: source.path,
      configurationPath: contract.path,
      orderKey: SHA256Digest.hex("canary-order-\(index)")
    )
  }
  let order = EvaluationPageRunOrder(
    canaryProcesses: [
      EvaluationPageCanaryProcessSlot(
        process: "A",
        workerProcessKey: processAKey,
        attempts: [
          slot(
            index: 1,
            process: "A",
            processKey: processAKey,
            condition: "clean",
            lessonSource: .clean,
            lessonPath: clean.path,
            publish: false
          ),
          slot(
            index: 2,
            process: "A",
            processKey: processAKey,
            condition: "nonempty",
            lessonSource: .artifact,
            lessonPath: nonempty.path,
            publish: true
          ),
        ]
      ),
      EvaluationPageCanaryProcessSlot(
        process: "B",
        workerProcessKey: processBKey,
        attempts: [
          slot(
            index: 3,
            process: "B",
            processKey: processBKey,
            condition: "clean",
            lessonSource: .clean,
            lessonPath: clean.path,
            publish: false
          ),
          slot(
            index: 4,
            process: "B",
            processKey: processBKey,
            condition: "nonempty",
            lessonSource: .durableActive,
            lessonPath: nil,
            publish: false
          ),
        ]
      ),
    ],
    taskSlots: [],
    synthesis: EvaluationPageSynthesisSlot(
      orderKey: SHA256Digest.hex("unused-synthesis"),
      workerProcessKey: SHA256Digest.hex("unused-synthesis-worker"),
      promptPath: "unused"
    )
  )
  let approvedContext = EvaluationFreezeContext(
    repositoryRoot: context.repositoryRoot,
    manifest: context.manifest,
    receipt: context.receipt,
    runtime: context.runtime,
    runOrderJSON: try makeApprovedEvaluationRunOrderJSON(
      manifestSHA256: context.receipt.manifest.sha256,
      canaryProcesses: order.canaryProcesses
    )
  )
  let paths = EvaluationController.PagePipelinePaths(
    evaluationRoot: configurations[0].evaluationRootURL
  )
  try EvaluationPathSecurity.ensurePrivateDirectory(at: paths.configurations)
  try EvaluationPathSecurity.ensurePrivateDirectory(at: paths.results)
  return CanaryControllerFixture(
    configurations: configurations,
    inputs: frozen.inputs,
    context: approvedContext,
    executable: frozen.executable,
    order: order,
    paths: paths,
    factory: EvaluationPageConfigurationFactory(
      freeze: approvedContext,
      freezeInputs: frozen.inputs,
      catalog: EvaluationPageFixtureCatalog(fixtures: [], byID: [:]),
      configurationDirectory: paths.configurations,
      resultDirectory: paths.results
    )
  )
}

private func testRelativePath(_ candidate: URL, under root: URL) -> String {
  candidate.standardizedFileURL.pathComponents
    .dropFirst(root.standardizedFileURL.pathComponents.count)
    .joined(separator: "/")
}

struct StaticEvaluationFreezeVerifier: EvaluationFreezeVerifying {
  let context: EvaluationFreezeContext

  func verify(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    context
  }
}

struct ScriptedEvaluationWorkerObservation: Sendable, Equatable {
  let kind: EvaluationWorkerInvocationKind
  let attemptIDs: [String]
  let sealedOutputKeyWasPresent: Bool
}

actor ScriptedEvaluationWorkerLauncher: EvaluationWorkerLaunching {
  typealias Script =
    @Sendable (
      EvaluationWorkerInvocation,
      [EvaluationAttemptConfiguration],
      Data?
    ) async throws -> EvaluationWorkerLaunchResult

  private let script: Script
  private var recorded: [ScriptedEvaluationWorkerObservation] = []
  private var recordedFailures: [String] = []

  init(script: @escaping Script) {
    self.script = script
  }

  var observations: [ScriptedEvaluationWorkerObservation] { recorded }
  var failures: [String] { recordedFailures }

  func launch(
    kind: EvaluationWorkerInvocationKind,
    executablePath _: String,
    invocationPath: String,
    sealedOutputKey: Data?
  ) async -> EvaluationWorkerLaunchResult {
    do {
      let invocation = try EvaluationJSONFile.decode(
        EvaluationWorkerInvocation.self,
        from: URL(fileURLWithPath: invocationPath)
      )
      let configurations = try Self.configurations(for: invocation)
      recorded.append(
        ScriptedEvaluationWorkerObservation(
          kind: kind,
          attemptIDs: configurations.map(\.attemptID),
          sealedOutputKeyWasPresent: sealedOutputKey != nil
        )
      )
      return try await script(invocation, configurations, sealedOutputKey)
    } catch {
      recordedFailures.append(String(reflecting: error))
      return EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
  }

  private static func configurations(
    for invocation: EvaluationWorkerInvocation
  ) throws -> [EvaluationAttemptConfiguration] {
    switch invocation.kind {
    case .attempt:
      return [
        try EvaluationJSONFile.decode(
          EvaluationAttemptConfiguration.self,
          from: URL(fileURLWithPath: invocation.configurationPath)
        )
      ]
    case .canaryProcess:
      let batch = try EvaluationJSONFile.decode(
        EvaluationWorkerBatchConfiguration.self,
        from: URL(fileURLWithPath: invocation.configurationPath)
      )
      return try batch.attemptConfigurationPaths.map { path in
        try EvaluationJSONFile.decode(
          EvaluationAttemptConfiguration.self,
          from: URL(fileURLWithPath: path)
        )
      }
    }
  }
}

struct StaticEvaluationProtectedArtifactRunner: EvaluationProtectedArtifactRunning {
  let output: Data

  func run(
    relativeExecutablePath _: String,
    arguments _: [String],
    protectedOutputURLs _: [URL],
    freeze _: EvaluationFreezeContext,
    captureLimit _: Int
  ) async throws -> Data {
    output
  }
}

actor ScriptedEvaluationProtectedArtifactRunner: EvaluationProtectedArtifactRunning {
  struct Invocation: Sendable, Equatable {
    let relativeExecutablePath: String
    let arguments: [String]
    let protectedOutputURLs: [URL]
  }

  private let output: Data
  private var storedInvocations: [Invocation] = []

  init(output: Data) {
    self.output = output
  }

  var invocations: [Invocation] { storedInvocations }

  func run(
    relativeExecutablePath: String,
    arguments: [String],
    protectedOutputURLs: [URL],
    freeze _: EvaluationFreezeContext,
    captureLimit _: Int
  ) async throws -> Data {
    storedInvocations.append(
      Invocation(
        relativeExecutablePath: relativeExecutablePath,
        arguments: arguments,
        protectedOutputURLs: protectedOutputURLs
      )
    )
    for url in protectedOutputURLs {
      try EvaluationDurablePublication.publish(output, to: url)
    }
    return output
  }
}
