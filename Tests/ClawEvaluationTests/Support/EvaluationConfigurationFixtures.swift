import ClawAgent
import ClawCore
import ClawSecrets
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

func makeEvaluationCredentialStateRoot(under root: URL) throws -> URL {
  let credentialRoot = root.appendingPathComponent("credential-state", isDirectory: true)
  try FileManager.default.createDirectory(at: credentialRoot, withIntermediateDirectories: true)
  try EncryptedFileSecretStore.seal(
    Secrets(telegramBotToken: "123:evaluation", llmApiKey: nil),
    stateRoot: credentialRoot
  )
  try EncryptedLLMCredentialStore(stateRoot: credentialRoot).save(
    StoredOAuthCredential(
      profileID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xAC)),
      accessToken: "evaluation-access-token",
      refreshToken: "evaluation-refresh-token",
      expiresAt: .distantFuture
    ),
    providerID: .openAIChatGPT
  )
  return credentialRoot
}

func makeEvaluationConfiguration(
  root: URL,
  executionProfile: EvaluationLearningExecutionProfile? = nil,
  carrierPath: String? = nil,
  carrierSHA256: String? = nil,
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
  task: [String: Any] = [:],
  inputSHA256: String? = nil,
  lessonSetDigestOverride: String? = nil,
  lessonArtifactPath: String? = nil,
  promotionReceiptPath: String? = nil,
  promotionReceiptSHA256: String? = nil,
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
    "task": task,
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
    "task": task,
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
    executionProfile: executionProfile,
    carrierPath: carrierPath,
    carrierSHA256: carrierSHA256,
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
    inputSHA256: inputSHA256 ?? SHA256Digest.hex(input),
    lessonSource: lessonSource,
    lessonArtifactPath: lessonSource == .artifact ? lessonURL.path : nil,
    promotionReceiptPath: promotionReceiptPath,
    promotionReceiptSHA256: promotionReceiptSHA256,
    publishLessonAsActive: publishLessonAsActive,
    taskPromptPath: promptURL.path,
    taskPromptSHA256: SHA256Digest.hex(prompt),
    resultPath: resultURL.path,
    fixedTimestamp: "2026-08-26T00:00:00Z",
    protocolSHA256: digest,
    lessonSetDigest: lessonSetDigestOverride ?? SHA256Digest.hex(lessonData),
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
