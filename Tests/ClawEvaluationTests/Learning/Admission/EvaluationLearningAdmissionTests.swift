import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationLearningAdmissionTests {
  @Test func verifierAcceptsCanonicalBoundArtifactsAndSelectsTheRouteForEachOperationKind()
    async throws
  {
    // given
    let kinds: [EvaluationLearningOperationKind] = [.task, .evaluator, .reflector]

    // when
    for kind in kinds {
      let fixture = try makeEvaluationLearningAdmissionFixture(operationKind: kind)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let context = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: fixture.invocationCoreDigest,
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: kind
      )

      // then — choosing the evaluator route for every kind would leave all three calls admitted.
      let expectedRoute: EvaluationLearningRouteBinding
      switch kind {
      case .task:
        expectedRoute = fixture.taskRoute
      case .evaluator:
        expectedRoute = fixture.evaluatorRoute
      case .reflector:
        expectedRoute = fixture.reflectorRoute
      }
      #expect(context.route == expectedRoute)
      #expect(context.route.retryBudget == expectedRoute.retryBudget)
    }
  }

  @Test func verifierRejectsNoncanonicalManifestBeforeAdmittingAnOperation() async throws {
    // given
    var fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manifestObject = try JSONSerialization.jsonObject(
      with: Data(contentsOf: fixture.manifestURL)
    )
    let noncanonical = try JSONSerialization.data(
      withJSONObject: manifestObject,
      options: [.prettyPrinted]
    )
    try noncanonical.write(to: fixture.manifestURL)
    fixture = try fixture.rebindingManifestAndOwnerApproval()

    // when
    let error = await #expect(throws: (any Error).self) {
      _ = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: fixture.invocationCoreDigest,
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: .evaluator
      )
    }

    // then — accepting ordinary JSON rather than the frozen bytes admits a representation change.
    #expect(error != nil)
  }

  @Test func verifierRejectsAChangedBoundArtifact() async throws {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var changedApproval = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: fixture.ownerApprovalURL)
      ) as? [String: Any]
    )
    changedApproval["owner_identity"] = "owner-02"
    try EvaluationCanonicalJSON.data(fromJSONObject: changedApproval).write(
      to: fixture.ownerApprovalURL
    )

    // when
    let error = await #expect(throws: EvaluationLearningAdmissionError.integrityFailure) {
      _ = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: fixture.invocationCoreDigest,
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: .evaluator
      )
    }

    // then — skipping the owner-approval rehash admits a post-approval identity replacement.
    #expect(error != nil)
  }

  @Test func verifierRejectsAnOperationCoreDigestThatDiffersFromTheStartedEvent() async throws {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    // when
    let error = await #expect(throws: (any Error).self) {
      _ = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: String(repeating: "9", count: 64),
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: .evaluator
      )
    }

    // then — omitting the invocation-core comparison permits a switched command invocation.
    #expect(error != nil)
  }

  @Test func verifierRejectsAChangedExecutable() async throws {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("changed executable".utf8).write(to: fixture.executableURL)

    // when
    let error = await #expect(throws: (any Error).self) {
      _ = try await fixture.verifier().verify(
        manifest: fixture.manifest,
        authorization: fixture.authorization,
        invocationCoreDigest: fixture.invocationCoreDigest,
        carrierSHA256: fixture.carrierSHA256,
        providerCallID: fixture.providerCallID,
        kind: .evaluator
      )
    }

    // then — checking only the manifest declaration leaves the executing binary unbound.
    #expect(error != nil)
  }

  @Test func taskVerifierAcceptsAProductionSizedExecutable() async throws {
    // given
    let byteCount = 16 * 1_024 * 1_024 + 1
    let fixture = try makeEvaluationLearningAdmissionFixture(
      operationKind: .task,
      executableByteCount: byteCount
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    // when
    let context = try await fixture.verifier().verify(
      manifest: fixture.manifest,
      authorization: fixture.authorization,
      invocationCoreDigest: fixture.invocationCoreDigest,
      carrierSHA256: fixture.carrierSHA256,
      providerCallID: fixture.providerCallID,
      kind: .task
    )

    // then — routing executable reads through the JSON limit rejects the default product size.
    #expect(
      context.executableSHA256 == SHA256Digest.hex(try Data(contentsOf: fixture.executableURL))
    )
    #expect(try fixture.executableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == byteCount)
  }

  @Test(arguments: [
    "provider_call_id",
    "carrier_digest",
    "route_digest",
  ])
  func verifierRejectsEachChangedProviderAdmissionField(_ changedField: String) async throws {
    // given
    let baseline = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: baseline.root) }
    let initial = try await baseline.verifier().verify(
      manifest: baseline.manifest,
      authorization: baseline.authorization,
      invocationCoreDigest: baseline.invocationCoreDigest,
      carrierSHA256: baseline.carrierSHA256,
      providerCallID: baseline.providerCallID,
      kind: .evaluator
    )
    let fixture = try makeEvaluationLearningAdmissionFixture(eventMutation: changedField)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let admission = fixture.liveAdmission(initial: initial)
    let configured = try makeEvaluationConfiguration(root: fixture.root)
    let provider = SequenceProvider([])
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let recorder = EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder
    ).run(
      configuration: configured.configuration,
      sendBudget: EvaluationSendBudgetSnapshot(
        stageAccountedTokens: 0,
        globalAccountedTokens: 0,
        stageResponsesSends: 0,
        globalResponsesSends: 0,
        stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
        stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
      ),
      integrityAdmission: { await admission.evaluate() }
    )

    // then — ignoring the production integrity admission reaches the provider.
    #expect(result.outcome == .harnessFailure)
    #expect(result.criticalCode == "evaluation-learning-integrity")
    #expect(await provider.requests.isEmpty)
  }

  @Test(arguments: [
    "task_attempts",
    "evaluator_calls",
    "reflector_calls",
    "responses_sends",
    "accounted_tokens",
  ])
  func verifierRejectsEachOwnerBudgetThatDiffersFromTheManifest(_ changedBudget: String)
    async throws
  {
    // given
    let baseline = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: baseline.root) }
    let initial = try await baseline.verifier().verify(
      manifest: baseline.manifest,
      authorization: baseline.authorization,
      invocationCoreDigest: baseline.invocationCoreDigest,
      carrierSHA256: baseline.carrierSHA256,
      providerCallID: baseline.providerCallID,
      kind: .evaluator
    )
    let fixture = try makeEvaluationLearningAdmissionFixture(approvalBudgetMutation: changedBudget)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let admission = fixture.liveAdmission(initial: initial)
    let configured = try makeEvaluationConfiguration(root: fixture.root)
    let provider = SequenceProvider([])
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let recorder = EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder
    ).run(
      configuration: configured.configuration,
      sendBudget: EvaluationSendBudgetSnapshot(
        stageAccountedTokens: 0,
        globalAccountedTokens: 0,
        stageResponsesSends: 0,
        globalResponsesSends: 0,
        stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
        stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
      ),
      integrityAdmission: { await admission.evaluate() }
    )

    // then — ignoring the production integrity admission reaches the provider.
    #expect(result.outcome == .harnessFailure)
    #expect(result.criticalCode == "evaluation-learning-integrity")
    #expect(await provider.requests.isEmpty)
  }

  @Test func verifierUsesOnlyTheManifestBytesItHashes() async throws {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let swappedManifest = try fixture.manifestData(missingUsageTokenProxy: 999_999)
    let verifier = EvaluationLearningAdmissionVerifier(
      runningExecutablePath: { fixture.executableURL.path },
      readFile: { url in
        let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
        if url == fixture.manifestURL {
          try swappedManifest.write(to: fixture.manifestURL)
        }
        return data
      }
    )

    // when
    let context = try await verifier.verify(
      manifest: fixture.manifest,
      authorization: fixture.authorization,
      invocationCoreDigest: fixture.invocationCoreDigest,
      carrierSHA256: fixture.carrierSHA256,
      providerCallID: fixture.providerCallID,
      kind: .evaluator
    )

    // then — decoding a reopened file would admit the swapped proxy despite hashing the original.
    #expect(context.missingUsageTokenProxy == 132_768)
  }

  @Test func verifierAllowsFullManifestFieldsButRejectsUnknownSwiftExecutionFields() async throws {
    // given
    var compatible = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: compatible.root) }
    try compatible.addManifestFields([
      "frozen_paths": ["corpus/page.json", "schemas/evaluator.json"],
      "schema_version": 1,
    ])
    compatible = try compatible.rebindingManifestAndOwnerApproval()
    var unknownProjection = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: unknownProjection.root) }
    try unknownProjection.addUnknownSwiftExecutionField()
    unknownProjection = try unknownProjection.rebindingManifestAndOwnerApproval()

    // when
    let context = try await compatible.verifier().verify(
      manifest: compatible.manifest,
      authorization: compatible.authorization,
      invocationCoreDigest: compatible.invocationCoreDigest,
      carrierSHA256: compatible.carrierSHA256,
      providerCallID: compatible.providerCallID,
      kind: .evaluator
    )
    let error = await #expect(throws: (any Error).self) {
      _ = try await unknownProjection.verifier().verify(
        manifest: unknownProjection.manifest,
        authorization: unknownProjection.authorization,
        invocationCoreDigest: unknownProjection.invocationCoreDigest,
        carrierSHA256: unknownProjection.carrierSHA256,
        providerCallID: unknownProjection.providerCallID,
        kind: .evaluator
      )
    }

    // then — allowing all nested execution keys lets an unfrozen route-control field through.
    #expect(context.route == compatible.evaluatorRoute)
    #expect(error != nil)
  }

  @Test func liveAdmissionDeniesWhenVerificationReturnsADifferentSuccessfulContext() async throws {
    // given
    let fixture = try makeEvaluationLearningAdmissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let initial = try await fixture.verifier().verify(
      manifest: fixture.manifest,
      authorization: fixture.authorization,
      invocationCoreDigest: fixture.invocationCoreDigest,
      carrierSHA256: fixture.carrierSHA256,
      providerCallID: fixture.providerCallID,
      kind: .evaluator
    )
    let changed = EvaluationLearningAdmissionContext(
      jobID: initial.jobID,
      operationID: initial.operationID,
      attemptGeneration: initial.attemptGeneration,
      providerCallID: initial.providerCallID,
      manifestSHA256: initial.manifestSHA256,
      freezeCommit: initial.freezeCommit,
      executableSHA256: initial.executableSHA256,
      missingUsageTokenProxy: initial.missingUsageTokenProxy + 1,
      budgets: initial.budgets,
      route: initial.route
    )
    let admission = EvaluationLearningLiveAdmission(
      verifier: StaticEvaluationLearningAdmissionVerifier(context: changed),
      manifest: fixture.manifest,
      authorization: fixture.authorization,
      invocationCoreDigest: fixture.invocationCoreDigest,
      carrierSHA256: fixture.carrierSHA256,
      providerCallID: fixture.providerCallID,
      kind: .evaluator,
      initial: initial
    )

    // when
    let decision = await admission.evaluate()

    // then — treating successful re-verification as enough allows changed frozen limits mid-run.
    #expect(decision == .deny(cap: "evaluation-learning-integrity"))
  }
}
