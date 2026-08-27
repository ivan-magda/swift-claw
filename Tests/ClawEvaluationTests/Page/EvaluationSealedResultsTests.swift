import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationSealedResultsTests {
  @Test func sealedAttemptEnvelopeKeepsSemanticOutputUnavailableUntilJointUnseal() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "sealed-output")
    let semanticMarker = "SECRET-SEALED-SEMANTIC-ANSWER"
    let result = EvaluationAttemptResult(
      configuration: configured.configuration,
      processUUID: UUID(),
      processID: 1,
      runID: 2,
      sessionID: 3,
      startedAt: "2026-08-26T00:00:00Z",
      finishedAt: "2026-08-26T00:00:01Z",
      durationMilliseconds: 1_000,
      policyVersion: configured.configuration.expectedPolicyVersion,
      outcome: .completed,
      criticalCode: nil,
      rawOutput: semanticMarker,
      modelObservations: [],
      http: EvaluationHTTPSnapshot(
        responsesSends: [],
        credentialHTTPCalls: 0,
        integrityFailures: []
      ),
      outputCounts: AttemptOutputCounts(utf8Bytes: 0, graphemes: 0, limitExceeded: false),
      tools: [],
      usage: [],
      accountedTokens: 0,
      replacementDisposition: .ineligible,
      replacementReason: "scorable_output_exists",
      workspace: makeEvaluationResult(
        configuration: configured.configuration,
        replacementDisposition: .ineligible
      ).workspace,
      lockAcquisitionID: UUID()
    )
    let key = EvaluationSealedResultStore.makeEphemeralKey()

    // when
    let receipt = try EvaluationSealedResultStore.seal(
      result,
      keyData: key,
      resultURL: configured.configuration.resultURL
    )

    // then — the predictable plaintext result path remains absent before the explicit unseal.
    #expect(
      FileManager.default.fileExists(atPath: configured.configuration.resultURL.path) == false
    )
    let envelope = try Data(contentsOf: URL(fileURLWithPath: receipt.envelopePath))
    #expect(envelope.range(of: Data(semanticMarker.utf8)) == nil)
    #expect(
      try EvaluationSealedResultStore.unseal(
        receipt: receipt,
        keyData: key,
        expectedConfiguration: configured.configuration
      ).rawOutput == semanticMarker
    )
    #expect(throws: EvaluationSealedResultError.authenticationFailed) {
      _ = try EvaluationSealedResultStore.unseal(
        receipt: receipt,
        keyData: EvaluationSealedResultStore.makeEphemeralKey(),
        expectedConfiguration: configured.configuration
      )
    }
  }

  @Test func jointUnsealRejectsAWrongFrozenSlotBeforePublishingAnyPlaintext() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(
      root: root,
      attemptID: "sealed-joint",
      fixtureID: "pc-sealed-01",
      split: "sealed",
      stage: "sealed-pre-restart",
      condition: .clean
    )
    let result = makeEvaluationResult(
      configuration: configured.configuration,
      replacementDisposition: .ineligible
    )
    let key = EvaluationSealedResultStore.makeEphemeralKey()
    let sealed = try EvaluationSealedResultStore.seal(
      result,
      keyData: key,
      resultURL: configured.configuration.resultURL
    )
    let accepted = EvaluationController.AcceptedAttempt(
      originalConfigurationPath: configured.configurationURL.path,
      actualConfigurationPath: configured.configurationURL.path,
      payload: .sealed(sealed)
    )
    let correct = EvaluationPageTaskSlot(
      stage: "sealed-pre-restart",
      split: "sealed",
      orderIndex: configured.configuration.frozenOrderIndex,
      blockIndex: 0,
      orderKey: configured.configuration.frozenOrderKey,
      blockOrderKey: String(repeating: "b", count: 64),
      fixtureID: configured.configuration.fixtureID,
      replicate: configured.configuration.replicate,
      condition: "clean",
      lessonSource: .clean,
      workerProcessKey: String(repeating: "e", count: 64)
    )
    let wrongCondition = EvaluationPageTaskSlot(
      stage: correct.stage,
      split: correct.split,
      orderIndex: correct.orderIndex,
      blockIndex: correct.blockIndex,
      orderKey: correct.orderKey,
      blockOrderKey: correct.blockOrderKey,
      fixtureID: correct.fixtureID,
      replicate: correct.replicate,
      condition: "lesson-conditioned",
      lessonSource: .artifact,
      workerProcessKey: correct.workerProcessKey
    )
    let receiptURL = root.appendingPathComponent("joint-unseal.json")

    // when
    let error = #expect(throws: EvaluationSealedResultError.incompleteJointUnseal) {
      _ = try EvaluationSealedResultStore.jointlyUnseal(
        accepted: [accepted],
        slots: [wrongCondition],
        keyData: key,
        manifestSHA256: configured.configuration.approval.manifestSHA256,
        receiptURL: receiptURL
      )
    }
    let noPlaintextAfterFailure =
      FileManager.default.fileExists(atPath: configured.configuration.resultURL.path) == false
    let noReceiptAfterFailure = FileManager.default.fileExists(atPath: receiptURL.path) == false
    let unsealed = try EvaluationSealedResultStore.jointlyUnseal(
      accepted: [accepted],
      slots: [correct],
      keyData: key,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      receiptURL: receiptURL
    )

    // then — the wrong slot emits no plaintext before the full slot set validates.
    #expect(error != nil)
    #expect(noPlaintextAfterFailure)
    #expect(noReceiptAfterFailure)
    #expect(
      unsealed.attempts.map(\.result.attemptID) == [configured.configuration.attemptID]
    )
    #expect(unsealed.receipt.conditions == ["clean"])
    #expect(FileManager.default.fileExists(atPath: configured.configuration.resultURL.path))
  }

  @Test func regressionResultRemainsSealedUntilTheJointUnsealBoundary() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(
      root: root,
      attemptID: "regression-sealed",
      fixtureID: "pc-regression-01",
      split: "regression",
      stage: "regression",
      condition: .clean
    )
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let key = EvaluationSealedResultStore.makeEphemeralKey()
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, receivedKey in
      let configuration = try #require(configurations.first)
      let receivedKey = try #require(receivedKey)
      let result = makeEvaluationResult(
        configuration: configuration,
        replacementDisposition: .ineligible
      )
      try publishEvaluationAttemptProgress(
        invocation: invocation,
        configurations: configurations,
        results: [result]
      )
      _ = try EvaluationSealedResultStore.seal(
        result,
        keyData: receivedKey,
        resultURL: configuration.resultURL
      )
      return EvaluationWorkerLaunchResult(termination: .completed, processID: 42)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: configured.configuration.evaluationRootURL,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      freezeCommit: configured.configuration.provenance.freezeCommit,
      fixedTimestamp: configured.configuration.fixedTimestamp,
      journalName: "regression-sealed.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    let accepted = try await EvaluationController(
      launcher: launcher,
      freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context)
    ).executeBlocks(
      [
        EvaluationReplicateBlock(
          blockID: "regression-block",
          attempts: [
            EvaluationPlannedAttempt(
              configurationPath: configured.configurationURL.path,
              replacementConfigurationPath: nil
            )
          ]
        )
      ],
      executablePath: frozen.executable.path,
      freezeInputs: frozen.inputs,
      freeze: frozen.context,
      limits: PageEvaluationContract.pageLimits,
      sealedOutputKey: key,
      journal: journal,
      accumulator: &accumulator
    )

    // then
    #expect(accepted.count == 1)
    guard case .sealed = accepted[0].payload else {
      Issue.record("Regression result escaped the sealed controller branch")
      return
    }
    #expect(
      FileManager.default.fileExists(atPath: configured.configuration.resultURL.path) == false
    )
    #expect(await launcher.observations.map(\.sealedOutputKeyWasPresent) == [true])

    let slot = EvaluationPageTaskSlot(
      stage: "regression",
      split: "regression",
      orderIndex: configured.configuration.frozenOrderIndex,
      blockIndex: 0,
      orderKey: configured.configuration.frozenOrderKey,
      blockOrderKey: String(repeating: "b", count: 64),
      fixtureID: configured.configuration.fixtureID,
      replicate: configured.configuration.replicate,
      condition: "clean",
      lessonSource: .clean,
      workerProcessKey: String(repeating: "e", count: 64)
    )
    let unsealed = try EvaluationSealedResultStore.jointlyUnseal(
      accepted: accepted,
      slots: [slot],
      keyData: key,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      receiptURL: root.appendingPathComponent("regression-joint-unseal.json")
    )
    #expect(unsealed.attempts.map(\.result.attemptID) == [configured.configuration.attemptID])
    #expect(FileManager.default.fileExists(atPath: configured.configuration.resultURL.path))
  }

  @Test func sealedReplacementRetainsTheSupersededOriginalAfterJointUnseal() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try makeEvaluationConfiguration(
      root: root,
      attemptID: "regression-original",
      fixtureID: "pc-regression-01",
      split: EvaluationPageSplit.regression.rawValue,
      stage: EvaluationPageStage.regression.rawValue,
      condition: .clean
    )
    let replacement = try makeEvaluationReplacement(
      of: original.configuration,
      configurationDirectory: root.appendingPathComponent("artifacts", isDirectory: true)
    )
    let originalResult = makeEvaluationResult(
      configuration: original.configuration,
      replacementDisposition: .eligible,
      processUUID: try #require(
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")
      ),
      processID: 41,
      accountedTokens: 123
    )
    let replacementResult = makeEvaluationResult(
      configuration: replacement.configuration,
      replacementDisposition: .ineligible,
      processUUID: try #require(
        UUID(uuidString: "22222222-2222-2222-2222-222222222222")
      ),
      processID: 42,
      accountedTokens: 456
    )
    let results = [
      original.configuration.attemptID: originalResult,
      replacement.configuration.attemptID: replacementResult,
    ]
    let frozen = try makeEvaluationFreeze(root: root, configurations: [original.configuration])
    let key = EvaluationSealedResultStore.makeEphemeralKey()
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, receivedKey in
      let configuration = try #require(configurations.first)
      let result = try #require(results[configuration.attemptID])
      try publishEvaluationAttemptProgress(
        invocation: invocation,
        configurations: configurations,
        results: [result]
      )
      _ = try EvaluationSealedResultStore.seal(
        result,
        keyData: try #require(receivedKey),
        resultURL: configuration.resultURL
      )
      return EvaluationWorkerLaunchResult(termination: .completed, processID: result.processID)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: original.configuration.evaluationRootURL,
      manifestSHA256: original.configuration.approval.manifestSHA256,
      freezeCommit: original.configuration.provenance.freezeCommit,
      fixedTimestamp: original.configuration.fixedTimestamp,
      journalName: "sealed-replacement.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()
    let slot = EvaluationPageTaskSlot(
      stage: original.configuration.stage,
      split: original.configuration.split,
      orderIndex: original.configuration.frozenOrderIndex,
      blockIndex: 0,
      orderKey: original.configuration.frozenOrderKey,
      blockOrderKey: String(repeating: "b", count: 64),
      fixtureID: original.configuration.fixtureID,
      replicate: original.configuration.replicate,
      condition: original.configuration.condition.runOrderValue,
      lessonSource: .clean,
      workerProcessKey: String(repeating: "e", count: 64)
    )

    // when
    let accepted = try await EvaluationController(
      launcher: launcher,
      freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context)
    ).executeBlocks(
      [
        EvaluationReplicateBlock(
          blockID: "regression-replacement",
          attempts: [
            EvaluationPlannedAttempt(
              configurationPath: original.configurationURL.path,
              replacementConfigurationPath: replacement.configurationURL.path
            )
          ]
        )
      ],
      executablePath: frozen.executable.path,
      freezeInputs: frozen.inputs,
      freeze: frozen.context,
      limits: PageEvaluationContract.pageLimits,
      sealedOutputKey: key,
      journal: journal,
      accumulator: &accumulator
    )
    let plaintextWasSealed = [original, replacement].allSatisfy {
      FileManager.default.fileExists(atPath: $0.configuration.resultURL.path) == false
    }
    let unsealed = try EvaluationSealedResultStore.jointlyUnseal(
      accepted: accepted,
      slots: [slot],
      keyData: key,
      manifestSHA256: original.configuration.approval.manifestSHA256,
      receiptURL: root.appendingPathComponent("sealed-replacement-unseal.json")
    )

    // then — only the replacement is scored, while the original's complete typed result remains
    // auditable after the same confidentiality barrier and before the ephemeral key is discarded.
    #expect(plaintextWasSealed)
    #expect(unsealed.attempts.map(\.result.attemptID) == [replacement.configuration.attemptID])
    #expect(unsealed.receipt.supersededAttemptIDs == [original.configuration.attemptID])
    #expect(
      unsealed.receipt.supersededEnvelopeSHA256s
        == [try #require(accepted.first?.originalAttemptEvidenceSHA256)]
    )
    #expect(
      try EvaluationJSONFile.decode(
        EvaluationAttemptResult.self,
        from: original.configuration.resultURL
      ) == originalResult
    )
    #expect(
      try EvaluationJSONFile.decode(
        EvaluationAttemptResult.self,
        from: replacement.configuration.resultURL
      ) == replacementResult
    )
  }
}
