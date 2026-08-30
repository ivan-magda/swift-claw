import ClawCore
import ClawSubprocess
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationLearningTaskInvocationTests {
  @Test func pythonTaskArtifactsPassSwiftPathAndIdentityAdmission() async throws {
    // given
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixtureRoot = repository.appendingPathComponent(
      "experiments/scheduled-task-learning/scheduled-learning-v1/tests/interop/"
        + "task-admission-fixture",
      isDirectory: true
    )
    let storedInvocationURL = fixtureRoot.appendingPathComponent(
      "experiments/scheduled-task-learning/scheduled-learning-v1/results/task-attempts/"
        + "task-0/invocation.json"
    )
    let storedInput = try EvaluationWorkerInput.decode(from: storedInvocationURL)
    guard case .scheduledLearning(let storedInvocation) = storedInput else {
      Issue.record("Python fixture did not contain a scheduled-learning task invocation")
      return
    }
    let runtimeRepository = URL(fileURLWithPath: storedInvocation.manifest.repositoryRoot)
    let fixtureLock = try acquirePythonTaskAdmissionFixtureLock()
    defer { fixtureLock.release() }
    defer { try? FileManager.default.removeItem(at: runtimeRepository) }
    let executableURL = try materializePythonTaskAdmissionFixture(
      fixtureRoot: fixtureRoot,
      runtimeRepository: runtimeRepository
    )
    let invocationURL = URL(fileURLWithPath: storedInvocation.configurationPath)
      .deletingLastPathComponent()
      .appendingPathComponent("invocation.json")
    let input = try EvaluationWorkerInput.decode(from: invocationURL)
    guard case .scheduledLearning(let invocation) = input else {
      Issue.record("Python did not emit a scheduled-learning task invocation")
      return
    }
    let configuration = try EvaluationJSONFile.decode(
      EvaluationAttemptConfiguration.self,
      from: URL(fileURLWithPath: invocation.configurationPath)
    )
    let verifier = EvaluationLearningAdmissionVerifier(
      runningExecutablePath: { executableURL.path }
    )

    // when
    let error = await #expect(throws: PythonAdmissionSentinel.admitted) {
      _ = try await EvaluationWorker().runResult(
        invocation: invocation,
        credentialStateRoot: runtimeRepository.resolvingSymlinksInPath().path,
        admissionVerifier: verifier,
        makeResource: { _, _ in throw PythonAdmissionSentinel.admitted }
      )
    }

    // then
    #expect(error != nil)
    #expect(configuration.evaluationRoot == invocation.manifest.evaluationRoot)
    #expect(
      EvaluationPathSecurity.isStrictlyContained(
        configuration.resultURL,
        under: configuration.evaluationRootURL
      )
    )
  }

  @Test func workerInputSelectsOnlyTheExplicitM3Profile() throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    let invocationURL = fixture.root.appendingPathComponent("m3-invocation.json")
    try EvaluationCanonicalJSON.data(encoding: fixture.invocation).write(to: invocationURL)

    // when
    let input = try EvaluationWorkerInput.decode(from: invocationURL)

    // then
    guard case .scheduledLearning(let decoded) = input else {
      Issue.record("the explicit scheduled-learning-v1 profile did not select the M3 decoder")
      return
    }
    #expect(decoded == fixture.invocation)
  }

  @Test func legacyWorkerInputSelectsTheExistingInvocation() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let invocation = try makeLegacyWorkerInvocation(root: root)
    let invocationURL = root.appendingPathComponent("legacy-invocation.json")
    try EvaluationJSONFile.write(invocation, to: invocationURL)

    // when
    let input = try EvaluationWorkerInput.decode(from: invocationURL)

    // then
    guard case .legacy(let decoded) = input else {
      Issue.record("an invocation without execution_profile did not select the legacy decoder")
      return
    }
    #expect(decoded == invocation)
  }

  @Test func unknownExecutionProfileIsRejected() throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    let invocationData = try EvaluationCanonicalJSON.data(encoding: fixture.invocation)
    var object = try #require(
      JSONSerialization.jsonObject(
        with: invocationData
      ) as? [String: Any]
    )
    object["execution_profile"] = "scheduled-learning-v2"
    let invocationURL = fixture.root.appendingPathComponent("unknown-profile.json")
    try EvaluationCanonicalJSON.data(fromJSONObject: object).write(to: invocationURL)

    // when
    let error = #expect(throws: EvaluationWorkerInputError.unknownExecutionProfile) {
      _ = try EvaluationWorkerInput.decode(from: invocationURL)
    }

    // then
    #expect(error != nil)
  }

  @Test func m3WorkerInputRejectsNoncanonicalInvocationBytes() throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    let object = try #require(
      JSONSerialization.jsonObject(
        with: EvaluationCanonicalJSON.data(encoding: fixture.invocation)
      ) as? [String: Any]
    )
    let invocationURL = fixture.root.appendingPathComponent("noncanonical-m3-invocation.json")
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(
      to: invocationURL
    )

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidJSON) {
      _ = try EvaluationWorkerInput.decode(from: invocationURL)
    }

    // then — ordinary JSONDecoder acceptance would admit byte-different authorization.
    #expect(error != nil)
  }

  @Test func m3WorkerInputRejectsAnUnknownTopLevelKey() throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    var object = try #require(
      JSONSerialization.jsonObject(
        with: EvaluationCanonicalJSON.data(encoding: fixture.invocation)
      ) as? [String: Any]
    )
    object["unfrozen_control"] = true
    let invocationURL = fixture.root.appendingPathComponent("open-m3-invocation.json")
    try EvaluationCanonicalJSON.data(fromJSONObject: object).write(to: invocationURL)

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidJSON) {
      _ = try EvaluationWorkerInput.decode(from: invocationURL)
    }

    // then — direct Codable decoding ignores the added key.
    #expect(error != nil)
  }
}

private enum PythonAdmissionSentinel: Error {
  case admitted
}

private func acquirePythonTaskAdmissionFixtureLock() throws -> InstanceLock {
  while true {
    do {
      return try InstanceLock(
        path: "/tmp/swift-claw-scheduled-learning-v1-task-admission-v1.lock"
      )
    } catch InstanceLock.LockError.alreadyLocked {
      Thread.sleep(forTimeInterval: 0.01)
    }
  }
}

private func materializePythonTaskAdmissionFixture(
  fixtureRoot: URL,
  runtimeRepository: URL
) throws -> URL {
  let manager = FileManager.default
  try? manager.removeItem(at: runtimeRepository)
  let relativeExperiment = "experiments/scheduled-task-learning/scheduled-learning-v1"
  let storedExperiment = fixtureRoot.appendingPathComponent(relativeExperiment, isDirectory: true)
  let runtimeExperiment = runtimeRepository.appendingPathComponent(
    relativeExperiment,
    isDirectory: true
  )
  try manager.createDirectory(at: runtimeExperiment, withIntermediateDirectories: true)
  for directory in ["freeze", "results"] {
    try manager.copyItem(
      at: storedExperiment.appendingPathComponent(directory, isDirectory: true),
      to: runtimeExperiment.appendingPathComponent(directory, isDirectory: true)
    )
  }
  let executableRelativePath = try String(
    contentsOf: fixtureRoot.appendingPathComponent("executable-path.txt"),
    encoding: .utf8
  ).trimmingCharacters(in: .whitespacesAndNewlines)
  let components = executableRelativePath.split(separator: "/")
  guard
    executableRelativePath.hasPrefix("/") == false,
    components.isEmpty == false,
    components.contains("..") == false
  else {
    throw EvaluationLearningAdmissionError.invalidBinding
  }
  let executableURL = runtimeRepository.appendingPathComponent(executableRelativePath)
  try manager.createDirectory(
    at: executableURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try manager.copyItem(
    at: fixtureRoot.appendingPathComponent("claw-eval-stub"),
    to: executableURL
  )
  return executableURL
}

struct EvaluationLearningTaskInvocationFixture {
  let root: URL
  let configuration: EvaluationAttemptConfiguration
  let configurationURL: URL
  let invocation: EvaluationLearningTaskInvocation
  let admissionContext: EvaluationLearningAdmissionContext

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

func makeEvaluationLearningTaskInvocationFixture() throws
  -> EvaluationLearningTaskInvocationFixture
{
  let attempt = try makeLearningAttemptFixture(lessons: [])
  let root = attempt.root
  let configurationURL = root.appendingPathComponent("m3-task-configuration.json")
  try EvaluationJSONFile.write(attempt.configuration, to: configurationURL)
  let configurationData = try Data(contentsOf: configurationURL)
  let manifestURL = root.appendingPathComponent("manifest.json")
  let approvalURL = root.appendingPathComponent("owner-approval.json")
  let eventsURL = attempt.configuration.evaluationRootURL.appendingPathComponent(
    "events",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: true)
  let eventURL = eventsURL.appendingPathComponent("000001.json")
  try Data("manifest".utf8).write(to: manifestURL)
  try Data("approval".utf8).write(to: approvalURL)
  try Data("operation_started".utf8).write(to: eventURL)

  let providerCallID = ProviderCallID(
    rawValue: "00000000-0000-0000-0000-000000000001"
  )
  let manifest = EvaluationLearningManifestBinding(
    repositoryRoot: root.path,
    evaluationRoot: attempt.configuration.evaluationRootURL.path,
    manifestPath: manifestURL.path,
    manifestSHA256: attempt.configuration.approval.manifestSHA256,
    ownerApproval: EvaluationLearningArtifactBinding(
      path: approvalURL.path,
      sha256: String(repeating: "c", count: 64)
    )
  )
  let budget = makeEvaluationLearningTaskBudget()
  let core = EvaluationLearningTaskInvocationCore(
    executionProfile: .scheduledLearningV1,
    jobID: "scheduled-learning-job-01",
    operationID: "task-operation-01",
    attemptGeneration: 1,
    providerCallID: providerCallID,
    configurationPath: configurationURL.path,
    configurationSHA256: SHA256Digest.hex(configurationData),
    manifest: manifest,
    budget: budget
  )
  let invocation = EvaluationLearningTaskInvocation(
    executionProfile: core.executionProfile,
    jobID: core.jobID,
    operationID: core.operationID,
    attemptGeneration: core.attemptGeneration,
    providerCallID: core.providerCallID,
    configurationPath: core.configurationPath,
    configurationSHA256: core.configurationSHA256,
    manifest: core.manifest,
    budget: core.budget,
    authorization: EvaluationLearningOperationAuthorization(
      eventPath: eventURL.path,
      eventSHA256: String(repeating: "d", count: 64)
    )
  )
  let route = EvaluationLearningRouteBinding(
    providerReference: attempt.configuration.providerReference,
    wireModel: attempt.configuration.wireModel,
    retryBudget: PageEvaluationContract.runBudget.retryBudget,
    maxOutputTokens: PageEvaluationContract.runBudget.maxOutputTokens,
    maxOutputUTF8Bytes: PageEvaluationContract.outputLimits.maximumUTF8Bytes,
    maxOutputGraphemes: PageEvaluationContract.outputLimits.maximumGraphemes
  )
  let context = EvaluationLearningAdmissionContext(
    jobID: invocation.jobID,
    operationID: invocation.operationID,
    attemptGeneration: invocation.attemptGeneration,
    providerCallID: providerCallID,
    manifestSHA256: invocation.manifest.manifestSHA256,
    freezeCommit: attempt.configuration.provenance.freezeCommit,
    executableSHA256: attempt.configuration.provenance.executableSHA256,
    missingUsageTokenProxy: PageEvaluationContract.missingUsageTokenProxy,
    budgets: EvaluationLearningApprovedBudgets(
      taskAttempts: 10,
      evaluatorCalls: 5,
      reflectorCalls: 1,
      responsesSends: 38,
      accountedTokens: 5_045_184
    ),
    route: route
  )
  return EvaluationLearningTaskInvocationFixture(
    root: root,
    configuration: attempt.configuration,
    configurationURL: configurationURL,
    invocation: invocation,
    admissionContext: context
  )
}

func makeEvaluationLearningTaskBudget() -> EvaluationSendBudgetSnapshot {
  EvaluationSendBudgetSnapshot(
    stageAccountedTokens: 0,
    globalAccountedTokens: 0,
    stageResponsesSends: 0,
    globalResponsesSends: 0,
    stageAccountedTokenThreshold: 5_045_184,
    globalAccountedTokenThreshold: 5_045_184,
    stageResponsesSendCap: 38,
    globalResponsesSendCap: 38
  )
}

private func makeLegacyWorkerInvocation(root: URL) throws -> EvaluationWorkerInvocation {
  let configured = try makeEvaluationConfiguration(root: root)
  let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
  let journal = try EvaluationControllerJournal.startNew(
    evaluationRoot: configured.configuration.evaluationRootURL,
    manifestSHA256: configured.configuration.approval.manifestSHA256,
    freezeCommit: configured.configuration.provenance.freezeCommit,
    fixedTimestamp: configured.configuration.fixedTimestamp,
    journalName: "legacy-dispatch.jsonl"
  )
  let written = try EvaluationController.writeInvocation(
    kind: .attempt,
    configurationPath: configured.configurationURL.path,
    freeze: frozen.inputs,
    budget: EvaluationSendBudgetSnapshot(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
      stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
    ),
    evaluationRoot: configured.configuration.evaluationRootURL,
    journal: journal,
    attemptIDs: [configured.configuration.attemptID],
    maximumResponsesSends: PageEvaluationContract.maximumResponsesSendsPerAttempt
  )
  return try EvaluationJSONFile.decode(
    EvaluationWorkerInvocation.self,
    from: URL(fileURLWithPath: written.path)
  )
}
