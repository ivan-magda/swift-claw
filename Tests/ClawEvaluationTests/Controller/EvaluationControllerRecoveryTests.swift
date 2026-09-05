import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationControllerRecoveryTests {
  @Test func zeroProgressInterruptionRunsItsFrozenReplacementAtBlockEnd() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try makeEvaluationConfiguration(root: root, attemptID: "interrupted-original")
    let replacement = try makeEvaluationReplacement(
      of: original.configuration,
      configurationDirectory: root.appendingPathComponent("artifacts", isDirectory: true)
    )
    let frozen = try makeEvaluationFreeze(root: root, configurations: [original.configuration])
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
      let configuration = try #require(configurations.first)
      guard configuration.replacementOrdinal > 0 else {
        return EvaluationWorkerLaunchResult(termination: .interrupted, processID: 41)
      }
      let result = makeEvaluationResult(
        configuration: configuration,
        replacementDisposition: .ineligible
      )
      try publishEvaluationAttemptProgress(
        invocation: invocation,
        configurations: configurations,
        results: [result]
      )
      try EvaluationJSONFile.write(result, to: configuration.resultURL)
      return EvaluationWorkerLaunchResult(termination: .completed, processID: 42)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: original.configuration.evaluationRootURL,
      manifestSHA256: original.configuration.approval.manifestSHA256,
      freezeCommit: original.configuration.provenance.freezeCommit,
      fixedTimestamp: original.configuration.fixedTimestamp,
      journalName: "zero-progress-interruption.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    let accepted = try await EvaluationController(
      launcher: launcher,
      freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context)
    ).executeBlocks(
      [
        EvaluationReplicateBlock(
          blockID: "interrupted",
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
      sealedOutputKey: nil,
      journal: journal,
      accumulator: &accumulator
    )

    // then — write-ahead progress absence proves zero provider/tool work, so the one frozen
    // replacement remains eligible and the original terminal evidence is retained exactly once.
    #expect(
      await launcher.observations.flatMap(\.attemptIDs) == [
        original.configuration.attemptID,
        replacement.configuration.attemptID,
      ]
    )
    #expect(accepted.count == 1)
    #expect(accepted[0].originalAttemptEvidenceSHA256.map(SHA256Digest.isCanonicalHex) == true)
    #expect(accumulator.replacements == 1)
    let events = try String(
      decoding: EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url),
      as: UTF8.self
    )
    .split(separator: "\n")
    .map { try JSONDecoder().decode(EvaluationControllerJournalEvent.self, from: Data($0.utf8)) }
    let terminals = events.filter {
      $0.kind == .launchInterrupted
        && $0.attemptIDs == [original.configuration.attemptID]
    }
    #expect(terminals.count == 1)
    let terminal = try #require(terminals.first)
    #expect(terminal.observedResponsesSends == 0)
    #expect(terminal.observedFileReads == 0)
    #expect(terminal.observedAccountedTokens == 0)
    #expect(
      accepted[0].originalAttemptEvidenceSHA256
        == (try EvaluationController.evidenceSHA256(terminal))
    )
  }

  @Test func controllerDefersReplacementToTheEndOfItsReplicateBlock() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let originals = try ["a", "b", "c"].enumerated().map { index, attemptID in
      try makeEvaluationConfiguration(
        root: root,
        attemptID: attemptID,
        frozenOrderIndex: index,
        frozenOrderKey: SHA256Digest.hex("order:\(attemptID)")
      )
    }
    let replacement = try makeEvaluationReplacement(
      of: originals[0].configuration,
      configurationDirectory: root.appendingPathComponent("artifacts", isDirectory: true)
    )
    let frozen = try makeEvaluationFreeze(
      root: root,
      configurations: originals.map(\.configuration)
    )
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
      let configuration = try #require(configurations.first)
      let disposition: EvaluationReplacementDisposition =
        configuration.attemptID == "a"
        ? .eligible : .ineligible
      let result = makeEvaluationResult(
        configuration: configuration,
        replacementDisposition: disposition
      )
      try publishEvaluationAttemptProgress(
        invocation: invocation,
        configurations: configurations,
        results: [result]
      )
      try EvaluationJSONFile.write(result, to: configuration.resultURL)
      return EvaluationWorkerLaunchResult(termination: .completed, processID: 42)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: originals[0].configuration.evaluationRootURL,
      manifestSHA256: originals[0].configuration.approval.manifestSHA256,
      freezeCommit: originals[0].configuration.provenance.freezeCommit,
      fixedTimestamp: originals[0].configuration.fixedTimestamp,
      journalName: "replacement-order.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    let accepted = try await EvaluationController(
      launcher: launcher,
      freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context)
    ).executeBlocks(
      [
        EvaluationReplicateBlock(
          blockID: "first",
          attempts: [
            EvaluationPlannedAttempt(
              configurationPath: originals[0].configurationURL.path,
              replacementConfigurationPath: replacement.configurationURL.path
            ),
            EvaluationPlannedAttempt(
              configurationPath: originals[1].configurationURL.path,
              replacementConfigurationPath: nil
            ),
          ]
        ),
        EvaluationReplicateBlock(
          blockID: "second",
          attempts: [
            EvaluationPlannedAttempt(
              configurationPath: originals[2].configurationURL.path,
              replacementConfigurationPath: nil
            )
          ]
        ),
      ],
      executablePath: frozen.executable.path,
      freezeInputs: frozen.inputs,
      freeze: frozen.context,
      limits: PageEvaluationContract.pageLimits,
      sealedOutputKey: nil,
      journal: journal,
      accumulator: &accumulator
    )

    // then — B completes before A-r1, while C cannot be pulled into the first block.
    #expect(await launcher.observations.flatMap(\.attemptIDs) == ["a", "b", "a-r1", "c"])
    #expect(await launcher.failures.isEmpty)
    #expect(accepted.count == 3)
    #expect(accepted[1].originalAttemptEvidenceSHA256.map(SHA256Digest.isCanonicalHex) == true)
  }

  @Test(arguments: [false, true])
  func interruptedWorkerAdmitsACompleteDurableOutputBeforeConsideringReplacement(
    sealed: Bool
  ) async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(
      root: root,
      attemptID: sealed ? "interrupted-sealed" : "interrupted-plain",
      fixtureID: sealed ? "pc-regression-01" : "pc-development-01",
      split: sealed
        ? EvaluationPageSplit.regression.rawValue : EvaluationPageSplit.development.rawValue,
      stage: sealed
        ? EvaluationPageStage.regression.rawValue : EvaluationPageStage.development.rawValue,
      condition: .clean
    )
    let recordedSend = makeEvaluationResponsesSend(
      sequence: 1,
      bodySHA256: String(repeating: "a", count: 64),
      normalizedStructureSHA256: String(repeating: "b", count: 64)
    )
    let result = makeEvaluationResult(
      configuration: configured.configuration,
      replacementDisposition: .ineligible,
      processID: 41,
      responsesSends: [recordedSend],
      accountedTokens: 37
    )
    let frozen = try makeEvaluationFreeze(
      root: root,
      configurations: [configured.configuration]
    )
    let key = sealed ? EvaluationSealedResultStore.makeEphemeralKey() : nil
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, receivedKey in
      let configuration = try #require(configurations.first)
      try publishEvaluationAttemptProgress(
        invocation: invocation,
        configurations: configurations,
        results: [result]
      )
      if let receivedKey {
        _ = try EvaluationSealedResultStore.seal(
          result,
          keyData: receivedKey,
          resultURL: configuration.resultURL
        )
      } else {
        try EvaluationJSONFile.write(result, to: configuration.resultURL)
      }
      return EvaluationWorkerLaunchResult(termination: .interrupted, processID: result.processID)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: configured.configuration.evaluationRootURL,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      freezeCommit: configured.configuration.provenance.freezeCommit,
      fixedTimestamp: configured.configuration.fixedTimestamp,
      journalName: "\(configured.configuration.attemptID).jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    let outcome = try await EvaluationController(
      launcher: launcher,
      freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context)
    ).runOne(
      executablePath: frozen.executable.path,
      configurationPath: configured.configurationURL.path,
      freezeInputs: frozen.inputs,
      freeze: frozen.context,
      limits: PageEvaluationContract.pageLimits,
      sealedOutputKey: key,
      journal: journal,
      accumulator: &accumulator
    )

    // then — a post-write/pre-exit signal retains the exact result and accounting; treating the
    // interrupted termination first would discard it and schedule a replacement.
    switch outcome {
    case .result(let admitted):
      #expect(sealed == false)
      #expect(admitted == result)
    case .sealed(let receipt):
      #expect(sealed)
      #expect(receipt.attemptID == result.attemptID)
    case .missing:
      Issue.record("A complete durable result was discarded as an interrupted attempt")
    }
    #expect(accumulator.completedAttemptIDs == [result.attemptID])
    #expect(accumulator.accountedTokens == result.accountedTokens)
    #expect(accumulator.responsesSends == 1)
    #expect(accumulator.replacements == 0)
    let events = try String(
      decoding: EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url),
      as: UTF8.self
    )
    .split(separator: "\n")
    .map { try JSONDecoder().decode(EvaluationControllerJournalEvent.self, from: Data($0.utf8)) }
    let terminals = events.filter { $0.kind == .launchInterrupted }
    #expect(terminals.count == 1)
    let terminal = try #require(terminals.first)
    #expect(terminal.observedResponsesSends == 1)
    #expect(terminal.observedFileReads == 0)
    #expect(terminal.observedAccountedTokens == result.accountedTokens)
  }

  @Test(arguments: [false, true])
  func interruptedWorkerRejectsMalformedOrPartialDurableOutput(sealed: Bool) async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(
      root: root,
      attemptID: sealed ? "interrupted-sealed-partial" : "interrupted-plain-malformed",
      fixtureID: sealed ? "pc-regression-01" : "pc-development-01",
      split: sealed
        ? EvaluationPageSplit.regression.rawValue : EvaluationPageSplit.development.rawValue,
      stage: sealed
        ? EvaluationPageStage.regression.rawValue : EvaluationPageStage.development.rawValue,
      condition: .clean
    )
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
      let configuration = try #require(configurations.first)
      let progress = try EvaluationAttemptProgressRecorder.start(
        invocation: invocation,
        configurations: configurations
      )
      try progress.recordResponsesSend(
        attemptID: configuration.attemptID,
        request: makeEvaluationResponsesSend(sequence: 1)
      )
      if sealed {
        try progress.recordFileRead(attemptID: configuration.attemptID)
        try progress.recordUsage(
          attemptID: configuration.attemptID,
          usage: ProviderUsage(
            providerCallID: ProviderCallID(rawValue: "interrupted-reported"),
            runId: 1,
            sessionId: 1,
            model: PageEvaluationContract.wireModel,
            promptTokens: 19,
            completionTokens: 18,
            costUSD: 0,
            costSource: .providerReturned,
            isEstimated: false,
            ts: Date(timeIntervalSince1970: 0)
          )
        )
      }
      let outputURL =
        sealed
        ? EvaluationSealedResultStore.envelopeURL(for: configuration.resultURL)
        : configuration.resultURL
      try EvaluationDurablePublication.publish(Data(#"{"schema_version":1}"#.utf8), to: outputURL)
      return EvaluationWorkerLaunchResult(termination: .interrupted, processID: 41)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: configured.configuration.evaluationRootURL,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      freezeCommit: configured.configuration.provenance.freezeCommit,
      fixedTimestamp: configured.configuration.fixedTimestamp,
      journalName: "\(configured.configuration.attemptID).jsonl"
    )
    var accumulator = EvaluationController.Accumulator()
    let expected = EvaluationPagePipelineError.invalidBatch(
      sealed ? "sealed_attempt_output_incomplete" : "attempt_result_invalid"
    )

    // when
    await #expect(throws: expected) {
      _ = try await EvaluationController(
        launcher: launcher,
        freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context)
      ).runOne(
        executablePath: frozen.executable.path,
        configurationPath: configured.configurationURL.path,
        freezeInputs: frozen.inputs,
        freeze: frozen.context,
        limits: PageEvaluationContract.pageLimits,
        sealedOutputKey: sealed ? EvaluationSealedResultStore.makeEphemeralKey() : nil,
        journal: journal,
        accumulator: &accumulator
      )
    }

    // then — malformed plaintext and a partial sealed pair are integrity evidence, never proof
    // that a clean replacement is permitted.
    #expect(accumulator.replacements == 0)
    #expect(accumulator.completedAttemptIDs.isEmpty)
    #expect(accumulator.responsesSends == 1)
    let expectedFileReads = sealed ? 1 : 0
    let expectedTokens = sealed ? 37 : PageEvaluationContract.missingUsageTokenProxy
    #expect(accumulator.fileReads == expectedFileReads)
    #expect(accumulator.accountedTokens == expectedTokens)
    let events = try String(
      decoding: EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url),
      as: UTF8.self
    )
    .split(separator: "\n")
    .map { try JSONDecoder().decode(EvaluationControllerJournalEvent.self, from: Data($0.utf8)) }
    let terminals = events.filter { $0.kind == .launchInterrupted }
    #expect(terminals.count == 1)
    let terminal = try #require(terminals.first)
    #expect(terminal.observedResponsesSends == 1)
    #expect(terminal.observedFileReads == expectedFileReads)
    #expect(terminal.observedAccountedTokens == expectedTokens)
  }
}
