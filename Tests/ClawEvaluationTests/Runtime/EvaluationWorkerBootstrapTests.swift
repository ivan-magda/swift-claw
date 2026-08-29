import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationWorkerBootstrapTests {
  @Test(arguments: LearningWorkerAdmissionMutation.allCases)
  func eachWorkerOwnedLearningAdmissionBindingRejectsBeforeExternalWork(
    _ mutation: LearningWorkerAdmissionMutation
  ) async throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    let verifier = StaticEvaluationLearningTaskAdmissionVerifier(
      context: mutation.apply(to: fixture.admissionContext)
    )
    let provider = SequenceProvider(scriptedTwoRoundResponses())
    let resourceCalls = EvaluationAsyncCounter()

    // when
    let error = await #expect(throws: EvaluationLearningAdmissionError.integrityFailure) {
      _ = try await EvaluationWorker().runResult(
        invocation: fixture.invocation,
        admissionVerifier: verifier,
        makeResource: { _ in
          await resourceCalls.increment()
          return makeEvaluationLearningLiveResource(provider: provider)
        }
      )
    }

    // then — omitting the selected cross-binding reaches resource/provider construction.
    #expect(error != nil)
    #expect(await resourceCalls.value == 0)
    #expect(await provider.requests.isEmpty)
  }

  @Test func mismatchedEvaluationRootIsRejectedBeforeExternalWork() async throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    let alternateEvaluation = fixture.root.appendingPathComponent(
      "alternate-evaluation",
      isDirectory: true
    )
    let alternateResults = alternateEvaluation.appendingPathComponent("results", isDirectory: true)
    try FileManager.default.createDirectory(at: alternateResults, withIntermediateDirectories: true)
    var configurationObject = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: fixture.configurationURL)
      ) as? [String: Any]
    )
    configurationObject["evaluation_root"] = alternateEvaluation.path
    configurationObject["result_path"] =
      alternateResults.appendingPathComponent("attempt-1.json").path
    let configurationData = try EvaluationCanonicalJSON.data(fromJSONObject: configurationObject)
    try configurationData.write(to: fixture.configurationURL)
    let invocation = EvaluationLearningTaskInvocation(
      executionProfile: fixture.invocation.executionProfile,
      jobID: fixture.invocation.jobID,
      operationID: fixture.invocation.operationID,
      attemptGeneration: fixture.invocation.attemptGeneration,
      providerCallID: fixture.invocation.providerCallID,
      configurationPath: fixture.invocation.configurationPath,
      configurationSHA256: SHA256Digest.hex(configurationData),
      manifest: fixture.invocation.manifest,
      budget: fixture.invocation.budget,
      authorization: fixture.invocation.authorization
    )
    let verifier = StaticEvaluationLearningTaskAdmissionVerifier(
      context: fixture.admissionContext
    )
    let provider = SequenceProvider(scriptedTwoRoundResponses())
    let resourceCalls = EvaluationAsyncCounter()

    // when
    let error = await #expect(throws: EvaluationLearningAdmissionError.integrityFailure) {
      _ = try await EvaluationWorker().runResult(
        invocation: invocation,
        admissionVerifier: verifier,
        makeResource: { _ in
          await resourceCalls.increment()
          return makeEvaluationLearningLiveResource(provider: provider)
        }
      )
    }

    // then
    #expect(error != nil)
    #expect(await resourceCalls.value == 0)
    #expect(await provider.requests.isEmpty)
  }

  @Test func changedConfigurationIsRejectedBeforeExternalWork() async throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    var changedBytes = try Data(contentsOf: fixture.configurationURL)
    changedBytes.append(0x20)
    try changedBytes.write(to: fixture.configurationURL)
    let verifier = StaticEvaluationLearningTaskAdmissionVerifier(
      context: fixture.admissionContext
    )
    let provider = SequenceProvider(scriptedTwoRoundResponses())
    let resourceCalls = EvaluationAsyncCounter()

    // when
    let error = await #expect(throws: EvaluationLearningAdmissionError.integrityFailure) {
      _ = try await EvaluationWorker().runResult(
        invocation: fixture.invocation,
        admissionVerifier: verifier,
        makeResource: { _ in
          await resourceCalls.increment()
          return makeEvaluationLearningLiveResource(provider: provider)
        }
      )
    }

    // then
    #expect(error != nil)
    #expect(await resourceCalls.value == 0)
    #expect(await provider.requests.isEmpty)
  }

  @Test(arguments: WorkerPromotionReceiptMutation.allCases)
  func changedOrMissingPromotionReceiptStopsBeforeResourceConstruction(
    _ mutation: WorkerPromotionReceiptMutation
  ) async throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    let receiptURL = fixture.root.appendingPathComponent("worker-promotion-receipt.json")
    let receiptData = try EvaluationCanonicalJSON.data(fromJSONObject: ["schema_version": 1])
    try receiptData.write(to: receiptURL)
    var configurationObject = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.configurationURL))
        as? [String: Any]
    )
    configurationObject["condition"] = EvaluationCondition.postRestartLessonConditioned.rawValue
    configurationObject["lesson_source"] = EvaluationLessonSource.durableActive.rawValue
    configurationObject["promotion_receipt_path"] = receiptURL.path
    configurationObject["promotion_receipt_sha256"] = SHA256Digest.hex(receiptData)
    configurationObject["split"] = "sealed"
    configurationObject["stage"] = "sealed-post-restart"
    let configurationData = try EvaluationCanonicalJSON.data(fromJSONObject: configurationObject)
    try configurationData.write(to: fixture.configurationURL)
    let invocation = EvaluationLearningTaskInvocation(
      executionProfile: fixture.invocation.executionProfile,
      jobID: fixture.invocation.jobID,
      operationID: fixture.invocation.operationID,
      attemptGeneration: fixture.invocation.attemptGeneration,
      providerCallID: fixture.invocation.providerCallID,
      configurationPath: fixture.invocation.configurationPath,
      configurationSHA256: SHA256Digest.hex(configurationData),
      manifest: fixture.invocation.manifest,
      budget: fixture.invocation.budget,
      authorization: fixture.invocation.authorization
    )
    if mutation == .missing {
      try FileManager.default.removeItem(at: receiptURL)
    } else {
      try Data("changed promotion receipt".utf8).write(to: receiptURL)
    }
    let provider = SequenceProvider(scriptedTwoRoundResponses())
    let resourceCalls = EvaluationAsyncCounter()

    // when
    let error = await #expect(throws: (any Error).self) {
      _ = try await EvaluationWorker().runResult(
        invocation: invocation,
        admissionVerifier: StaticEvaluationLearningTaskAdmissionVerifier(
          context: fixture.admissionContext
        ),
        makeResource: { _ in
          await resourceCalls.increment()
          return makeEvaluationLearningLiveResource(provider: provider)
        }
      )
    }

    // then — materializer-only checking creates credentials before rejecting stale provenance.
    #expect(error != nil)
    #expect(await resourceCalls.value == 0)
    #expect(await provider.requests.isEmpty)
  }

  @Test func firstRoundTripUsesTheAuthorizedProviderCallID() async throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    let verifier = StaticEvaluationLearningTaskAdmissionVerifier(
      context: fixture.admissionContext
    )
    let provider = SequenceProvider(scriptedTwoRoundResponses())

    // when
    let result = try await EvaluationWorker().runResult(
      invocation: fixture.invocation,
      admissionVerifier: verifier,
      makeResource: { _ in
        makeEvaluationLearningLiveResource(provider: provider)
      }
    )

    // then
    #expect(result.usage.first?.providerCallID == fixture.invocation.providerCallID.rawValue)
  }

  @Test func workerRejectsSamePathConfigurationMutationBeforeFreezeOrProviderSetup() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: configured.configuration.evaluationRootURL,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      freezeCommit: configured.configuration.provenance.freezeCommit,
      fixedTimestamp: configured.configuration.fixedTimestamp,
      journalName: "configuration-mutation.jsonl"
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
    let invocation = try EvaluationJSONFile.decode(
      EvaluationWorkerInvocation.self,
      from: URL(fileURLWithPath: written.path)
    )
    var changedBytes = try Data(contentsOf: configured.configurationURL)
    changedBytes.append(0x20)
    try changedBytes.write(to: configured.configurationURL)
    let freezeVerifier = RefusingIfCalledFreezeVerifier()

    // when
    let error = await #expect(throws: EvaluationWorkerInvocationError.invalidConfigurationSnapshot)
    {
      _ = try await EvaluationWorker().runResult(
        invocation: invocation,
        freezeVerifier: freezeVerifier
      )
    }

    // then — a same-path TOCTOU mutation cannot reach freeze, credentials, or the provider.
    #expect(error != nil)
    #expect(await freezeVerifier.calls == 0)
  }

  @Test func policyMismatchStopsBeforeTheProviderBoundary() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(
      root: root,
      expectedPolicyVersion: String(repeating: "0", count: 16)
    )
    let provider = FailingStreamingProvider(
      cause: .terminal(status: nil, message: "unexpected provider call")
    )
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let runner = EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))
    )
    let expected = String(repeating: "0", count: 16)
    let observed = EvaluationPolicyInspector.policyVersion(
      evaluationRootURL: configured.configuration.evaluationRootURL
    )

    // when
    await #expect(
      throws: EvaluationAttemptError.policyMismatch(expected: expected, observed: observed)
    ) {
      _ = try await runner.run(
        configuration: configured.configuration,
        sendBudget: EvaluationSendBudgetSnapshot(
          stageAccountedTokens: 0,
          globalAccountedTokens: 0,
          stageResponsesSends: 0,
          globalResponsesSends: 0,
          stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
          stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
        )
      )
    }

    // then
    #expect(await provider.streamCalls == 0)
  }

  @Test func workerPublishesAuthenticatedCarrierEvidenceForAPolicyMismatch() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = String(repeating: "0", count: 16)
    let configured = try makeEvaluationConfiguration(
      root: root,
      attemptID: "worker-policy-mismatch",
      expectedPolicyVersion: expected
    )
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let context = EvaluationFreezeContext(
      repositoryRoot: frozen.context.repositoryRoot,
      manifest: frozen.context.manifest,
      receipt: frozen.context.receipt,
      runtime: frozen.context.runtime,
      runOrderJSON: try makeApprovedEvaluationRunOrderJSON(
        manifestSHA256: frozen.context.receipt.manifest.sha256,
        anchor: configured.configuration
      )
    )
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: configured.configuration.evaluationRootURL,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      freezeCommit: configured.configuration.provenance.freezeCommit,
      fixedTimestamp: configured.configuration.fixedTimestamp,
      journalName: "worker-policy-mismatch.jsonl"
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
    let invocation = try EvaluationJSONFile.decode(
      EvaluationWorkerInvocation.self,
      from: URL(fileURLWithPath: written.path)
    )
    let observed = EvaluationPolicyInspector.policyVersion(
      evaluationRootURL: configured.configuration.evaluationRootURL
    )

    // when
    let error = await #expect(
      throws: EvaluationAttemptError.policyMismatch(expected: expected, observed: observed)
    ) {
      _ = try await EvaluationWorker().runResult(
        invocation: invocation,
        freezeVerifier: StaticEvaluationFreezeVerifier(context: context)
      )
    }

    // then — deleting the worker catch would leave only a process exit and erase the authenticated
    // carrier reason before the controller can classify it.
    #expect(error != nil)
    let evidence = try EvaluationJSONFile.decode(
      EvaluationWorkerFailureEvidence.self,
      from: EvaluationWorkerFailureEvidence.url(for: configured.configuration.resultURL)
    )
    #expect(evidence.reason == .policyMismatch)
    #expect(evidence.classification == .carrierFailure)
    #expect(evidence.invocationID == invocation.invocationID)
    #expect(evidence.configurationSHA256 == invocation.configurationSHA256)
  }
}

private actor EvaluationAsyncCounter {
  private(set) var value = 0

  func increment() {
    value += 1
  }
}

enum WorkerPromotionReceiptMutation: String, CaseIterable, Sendable {
  case missing
  case changed
}

enum LearningWorkerAdmissionMutation: String, CaseIterable, Sendable {
  case jobID
  case operationID
  case attemptGeneration
  case providerCallID
  case manifestSHA256
  case freezeCommit
  case executableSHA256
  case missingUsageTokenProxy
  case taskAttempts
  case evaluatorCalls
  case reflectorCalls
  case responsesSends
  case accountedTokens
  case providerReference
  case wireModel
  case retryBudget
  case maxOutputTokens
  case maxOutputUTF8Bytes
  case maxOutputGraphemes

  func apply(
    to context: EvaluationLearningAdmissionContext
  ) -> EvaluationLearningAdmissionContext {
    var taskAttempts = context.budgets.taskAttempts
    var evaluatorCalls = context.budgets.evaluatorCalls
    var reflectorCalls = context.budgets.reflectorCalls
    var responsesSends = context.budgets.responsesSends
    var accountedTokens = context.budgets.accountedTokens
    switch self {
    case .taskAttempts:
      taskAttempts = 0
    case .evaluatorCalls:
      evaluatorCalls = 0
    case .reflectorCalls:
      reflectorCalls = 0
    case .responsesSends:
      responsesSends = 0
    case .accountedTokens:
      accountedTokens = 0
    default:
      break
    }
    let budgets = EvaluationLearningApprovedBudgets(
      taskAttempts: taskAttempts,
      evaluatorCalls: evaluatorCalls,
      reflectorCalls: reflectorCalls,
      responsesSends: responsesSends,
      accountedTokens: accountedTokens
    )
    let route = EvaluationLearningRouteBinding(
      providerReference: self == .providerReference
        ? "changed/provider" : context.route.providerReference,
      wireModel: self == .wireModel ? "changed-model" : context.route.wireModel,
      retryBudget: self == .retryBudget ? context.route.retryBudget + 1 : context.route.retryBudget,
      maxOutputTokens:
        self == .maxOutputTokens
        ? context.route.maxOutputTokens + 1 : context.route.maxOutputTokens,
      maxOutputUTF8Bytes:
        self == .maxOutputUTF8Bytes
        ? context.route.maxOutputUTF8Bytes + 1 : context.route.maxOutputUTF8Bytes,
      maxOutputGraphemes:
        self == .maxOutputGraphemes
        ? context.route.maxOutputGraphemes + 1 : context.route.maxOutputGraphemes
    )
    return EvaluationLearningAdmissionContext(
      jobID: self == .jobID ? "changed-job" : context.jobID,
      operationID: self == .operationID ? "changed-operation" : context.operationID,
      attemptGeneration:
        self == .attemptGeneration
        ? context.attemptGeneration + 1 : context.attemptGeneration,
      providerCallID:
        self == .providerCallID
        ? ProviderCallID(rawValue: "00000000-0000-0000-0000-000000000099")
        : context.providerCallID,
      manifestSHA256:
        self == .manifestSHA256 ? String(repeating: "9", count: 64) : context.manifestSHA256,
      freezeCommit:
        self == .freezeCommit ? String(repeating: "9", count: 40) : context.freezeCommit,
      executableSHA256:
        self == .executableSHA256 ? String(repeating: "9", count: 64) : context.executableSHA256,
      missingUsageTokenProxy:
        self == .missingUsageTokenProxy
        ? context.missingUsageTokenProxy + 1 : context.missingUsageTokenProxy,
      budgets: budgets,
      route: route
    )
  }
}

private actor RefusingIfCalledFreezeVerifier: EvaluationFreezeVerifying {
  private(set) var calls = 0

  func verify(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    calls += 1
    throw EvaluationHarnessTestError.unexpectedFreezeCall
  }
}
