import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationCanaryEvidenceTests {
  @Test func canaryEvidenceRequiresEveryFrozenRuntimeObservation() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let nonempty: [String: Any] = [
      "lesson_set_id": "candidate",
      "lessons": [
        [
          "lesson_id": "ignore-counters",
          "target_class": "noise.volatile_value",
          "text": "Ignore volatile counters that do not change a material task fact.",
        ]
      ],
      "schema_version": 1,
    ]
    let configurations = try [
      makeEvaluationConfiguration(
        root: root,
        attemptID: "canary-a-clean",
        stage: "canary",
        condition: .canary
      ).configuration,
      makeEvaluationConfiguration(
        root: root,
        attemptID: "canary-a-nonempty",
        stage: "canary",
        condition: .canary,
        lessonSource: .artifact,
        activeLessons: nonempty,
        publishLessonAsActive: true
      ).configuration,
      makeEvaluationConfiguration(
        root: root,
        attemptID: "canary-b-clean",
        stage: "canary",
        condition: .canary
      ).configuration,
      makeEvaluationConfiguration(
        root: root,
        attemptID: "canary-b-nonempty",
        stage: "canary",
        condition: .canary,
        lessonSource: .durableActive,
        activeLessons: nonempty
      ).configuration,
    ]
    let processA = UUID()
    let processB = UUID()
    func result(
      _ index: Int,
      outcome: EvaluationAttemptOutcome = .completed,
      requestedModel: String = PageEvaluationContract.wireModel,
      fence: Bool = true,
      tools: [EvaluationToolRecord] = [
        EvaluationToolRecord(
          name: EvaluationToolContract.requiredToolName,
          path: PageEvaluationContract.inputFileName,
          status: EvaluationToolContract.succeededStatus
        )
      ],
      regenerated: Bool = true,
      policy: String? = nil,
      lockAcquisitionID: UUID? = nil
    ) throws -> EvaluationAttemptResult {
      try makeCanaryEvidenceResult(
        configuration: configurations[index],
        processUUID: index < 2 ? processA : processB,
        sessionID: Int64(index + 1),
        lessonSetID: index.isMultiple(of: 2) ? "empty" : "candidate",
        lessonIDs: index.isMultiple(of: 2) ? [] : ["ignore-counters"],
        outcome: outcome,
        requestedModel: requestedModel,
        untrustedFencePresent: fence,
        tools: tools,
        inputWasRegenerated: regenerated,
        policyVersion: policy,
        lockAcquisitionID: lockAcquisitionID
      )
    }
    let valid = try (0..<4).map { try result($0) }
    var mutations: [[EvaluationAttemptResult]] = []
    func appendMutation(_ replacement: EvaluationAttemptResult) {
      var mutated = valid
      mutated[3] = replacement
      mutations.append(mutated)
    }
    appendMutation(try result(3, outcome: .providerFailure))
    appendMutation(try result(3, requestedModel: "wrong-model"))
    appendMutation(try result(3, fence: false))
    appendMutation(try result(3, tools: []))
    appendMutation(try result(3, regenerated: false))
    appendMutation(try result(3, policy: "ffffffffffffffff"))
    appendMutation(try result(3, lockAcquisitionID: UUID()))

    // when
    let evidence = try EvaluationCanaryEvidence(results: valid)
    let errors = mutations.map { mutation in
      #expect(throws: EvaluationPagePipelineError.canaryEvidenceMissing) {
        _ = try EvaluationCanaryEvidence(results: mutation)
      }
    }

    // then — each mutation reaches a distinct frozen observation guard.
    #expect(evidence.processAUUID == processA)
    #expect(evidence.processBUUID == processB)
    #expect(errors.allSatisfy { $0 != nil })
  }

  @Test func canaryRejectsResultMetadataThatDivergesFromDurableProgress() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeCanaryControllerFixture(root: root)
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
      let processUUID = UUID()
      let results = try configurations.enumerated().map { index, configuration in
        try makeCanaryEvidenceResult(
          configuration: configuration,
          processUUID: processUUID,
          sessionID: Int64(index + 1),
          lessonSetID: configuration.lessonSource == .clean ? "empty" : "candidate",
          lessonIDs: configuration.lessonSource == .clean ? [] : ["ignore-counters"]
        )
      }
      try publishEvaluationAttemptProgress(
        invocation: invocation,
        configurations: configurations,
        results: results
      )
      for (index, configuration) in configurations.enumerated() {
        if index == 0 {
          var object = try #require(
            JSONSerialization.jsonObject(
              with: EvaluationCanonicalJSON.data(encoding: results[index])
            ) as? [String: Any]
          )
          var http = try #require(object["http"] as? [String: Any])
          var requests = try #require(http["responsesSends"] as? [[String: Any]])
          requests[0]["body_sha256"] = String(repeating: "f", count: 64)
          http["responsesSends"] = requests
          object["http"] = http
          try EvaluationDurablePublication.publish(
            EvaluationCanonicalJSON.data(fromJSONObject: object),
            to: configuration.resultURL
          )
        } else {
          try EvaluationJSONFile.write(results[index], to: configuration.resultURL)
        }
      }
      return EvaluationWorkerLaunchResult(termination: .completed, processID: 41)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: fixture.configurations[0].evaluationRootURL,
      manifestSHA256: fixture.configurations[0].approval.manifestSHA256,
      freezeCommit: fixture.configurations[0].provenance.freezeCommit,
      fixedTimestamp: fixture.configurations[0].fixedTimestamp,
      journalName: "canary-progress-mismatch.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    await #expect(throws: EvaluationControllerError.resultProgressMismatch) {
      _ = try await EvaluationController(
        launcher: launcher,
        freezeVerifier: StaticEvaluationFreezeVerifier(context: fixture.context)
      ).executeCanary(
        EvaluationCanaryExecutionRequest(
          order: fixture.order,
          factory: fixture.factory,
          executablePath: fixture.executable.path,
          journal: journal,
          configurationPaths: [fixture.paths.canaryProcessA, fixture.paths.canaryProcessB],
          evidenceURL: fixture.paths.canarySummary
        ),
        accumulator: &accumulator
      )
    }

    // then — the progress ledger authenticates request-parity metadata before canary admission.
    #expect(
      accumulator.responsesSends == PageEvaluationContract.canaryResponsesSendsPerProcess
    )
    #expect(accumulator.fileReads == PageEvaluationContract.canaryAttemptsPerProcess)
    let events = try String(
      decoding: EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url),
      as: UTF8.self
    )
    .split(separator: "\n")
    .map { try JSONDecoder().decode(EvaluationControllerJournalEvent.self, from: Data($0.utf8)) }
    let terminals = events.filter { $0.kind == .launchCompleted }
    #expect(terminals.count == 1)
    let terminal = try #require(terminals.first)
    #expect(
      terminal.observedResponsesSends == PageEvaluationContract.canaryResponsesSendsPerProcess
    )
    #expect(terminal.observedFileReads == PageEvaluationContract.canaryAttemptsPerProcess)
    #expect(terminal.observedAccountedTokens == 0)
  }

  @Test func canaryRejectedProcessPreservesAuthenticatedCarrierEvidence() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeCanaryControllerFixture(root: root)
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
      let configuration = try #require(configurations.first)
      try EvaluationJSONFile.write(
        EvaluationWorkerFailureEvidence(
          reason: .policyMismatch,
          invocation: invocation,
          configuration: configuration
        ),
        to: EvaluationWorkerFailureEvidence.url(for: configuration.resultURL)
      )
      return EvaluationWorkerLaunchResult(termination: .rejected, processID: 41)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: fixture.configurations[0].evaluationRootURL,
      manifestSHA256: fixture.configurations[0].approval.manifestSHA256,
      freezeCommit: fixture.configurations[0].provenance.freezeCommit,
      fixedTimestamp: fixture.configurations[0].fixedTimestamp,
      journalName: "canary-carrier-evidence.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    let error = await #expect(
      throws: EvaluationPagePipelineError.carrierFailure(
        EvaluationWorkspaceFailureReason.policyMismatch.rawValue
      )
    ) {
      _ = try await EvaluationController(
        launcher: launcher,
        freezeVerifier: StaticEvaluationFreezeVerifier(context: fixture.context)
      ).executeCanary(
        EvaluationCanaryExecutionRequest(
          order: fixture.order,
          factory: fixture.factory,
          executablePath: fixture.executable.path,
          journal: journal,
          configurationPaths: [fixture.paths.canaryProcessA, fixture.paths.canaryProcessB],
          evidenceURL: fixture.paths.canarySummary
        ),
        accumulator: &accumulator
      )
    }

    // then — deleting the canary rejection-side evidence classifier would collapse this into the
    // generic nonzero-exit invalid result.
    #expect(error != nil)
    #expect(await launcher.observations.count == 1)
    let events = try String(
      decoding: EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url),
      as: UTF8.self
    )
    .split(separator: "\n")
    .map { try JSONDecoder().decode(EvaluationControllerJournalEvent.self, from: Data($0.utf8)) }
    let terminals = events.filter { $0.kind == .launchRejected }
    #expect(terminals.count == 1)
    let terminal = try #require(terminals.first)
    #expect(terminal.observedResponsesSends == 0)
    #expect(terminal.observedFileReads == 0)
    #expect(terminal.observedAccountedTokens == 0)
  }

  @Test func canaryWorkerPublishesPolicyMismatchEvidenceBeforeCredentialSetup() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeCanaryControllerFixture(root: root)
    let expected = String(repeating: "0", count: 16)
    var runtimeObject = try #require(
      JSONSerialization.jsonObject(
        with: EvaluationCanonicalJSON.data(encoding: fixture.context.runtime)
      ) as? [String: Any]
    )
    runtimeObject["expected_policy_version"] = expected
    let runtime = try JSONDecoder().decode(
      EvaluationRuntimeConfiguration.self,
      from: EvaluationCanonicalJSON.data(fromJSONObject: runtimeObject)
    )
    let context = EvaluationFreezeContext(
      repositoryRoot: fixture.context.repositoryRoot,
      manifest: fixture.context.manifest,
      receipt: fixture.context.receipt,
      runtime: runtime,
      runOrderJSON: fixture.context.runOrderJSON
    )
    let factory = EvaluationPageConfigurationFactory(
      freeze: context,
      freezeInputs: fixture.inputs,
      catalog: EvaluationPageFixtureCatalog(fixtures: [], byID: [:]),
      configurationDirectory: fixture.paths.configurations,
      resultDirectory: fixture.paths.results
    )
    let configurations = try factory.makeCanaryConfigurations(
      process: fixture.order.canaryProcesses[0]
    )
    let configurationURLs = try configurations.map { configuration in
      let url = fixture.paths.configurations.appendingPathComponent(
        "\(configuration.attemptID).json"
      )
      try EvaluationJSONFile.write(configuration, to: url)
      return url
    }
    let batchURL = fixture.paths.configurations.appendingPathComponent("canary-policy-batch.json")
    try EvaluationJSONFile.write(
      EvaluationWorkerBatchConfiguration(
        attemptConfigurationPaths: configurationURLs.map(\.path)
      ),
      to: batchURL
    )
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: runtime.evaluationRootURL,
      manifestSHA256: context.receipt.manifest.sha256,
      freezeCommit: context.receipt.freezeCommit,
      fixedTimestamp: runtime.fixedTimestamp,
      journalName: "canary-worker-policy.jsonl"
    )
    let written = try EvaluationController.writeInvocation(
      kind: .canaryProcess,
      configurationPath: batchURL.path,
      freeze: fixture.inputs,
      budget: EvaluationSendBudgetSnapshot(
        stageAccountedTokens: 0,
        globalAccountedTokens: 0,
        stageResponsesSends: 0,
        globalResponsesSends: 0,
        stageAccountedTokenThreshold: PageEvaluationContract.canaryLimits.accountedTokenThreshold,
        stageResponsesSendCap: PageEvaluationContract.canaryLimits.maximumResponsesSends
      ),
      evaluationRoot: runtime.evaluationRootURL,
      journal: journal,
      attemptIDs: configurations.map(\.attemptID),
      maximumResponsesSends: PageEvaluationContract.canaryResponsesSendsPerProcess
    )
    let invocation = try EvaluationJSONFile.decode(
      EvaluationWorkerInvocation.self,
      from: URL(fileURLWithPath: written.path)
    )
    let observed = EvaluationPolicyInspector.policyVersion(
      evaluationRootURL: runtime.evaluationRootURL
    )

    // when
    let error = await #expect(
      throws: EvaluationAttemptError.policyMismatch(expected: expected, observed: observed)
    ) {
      _ = try await EvaluationWorker().runCanaryResults(
        invocation: invocation,
        freezeVerifier: StaticEvaluationFreezeVerifier(context: context)
      )
    }

    // then — the shared failure-evidence wrapper must also own the canary worker path, before an
    // OAuth credential or inference request can hide the exact carrier classification.
    #expect(error != nil)
    let evidence = try EvaluationJSONFile.decode(
      EvaluationWorkerFailureEvidence.self,
      from: EvaluationWorkerFailureEvidence.url(for: configurations[0].resultURL)
    )
    #expect(evidence.reason == .policyMismatch)
    #expect(evidence.classification == .carrierFailure)
    #expect(evidence.invocationID == invocation.invocationID)
  }
}
