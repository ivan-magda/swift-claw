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

private actor RefusingIfCalledFreezeVerifier: EvaluationFreezeVerifying {
  private(set) var calls = 0

  func verify(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    calls += 1
    throw EvaluationHarnessTestError.unexpectedFreezeCall
  }
}
