import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationControllerAdmissionTests {
  @Test func changedLiveApprovalStopsBeforeAttemptWorkerLaunch() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "changed-approval")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let changedApproval = evaluationContextChangingApprovalBody(frozen.context)
    let verifier = StaticEvaluationFreezeVerifier(
      liveContext: changedApproval,
      localContext: frozen.context
    )
    let launcher = ScriptedEvaluationWorkerLauncher { _, _, _ in
      EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: configured.configuration.evaluationRootURL,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      freezeCommit: configured.configuration.provenance.freezeCommit,
      fixedTimestamp: configured.configuration.fixedTimestamp,
      journalName: "changed-approval.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    await #expect(throws: EvaluationControllerError.freezeChangedBeforeLaunch) {
      _ = try await EvaluationController(
        launcher: launcher,
        freezeVerifier: verifier
      ).runOne(
        executablePath: frozen.executable.path,
        configurationPath: configured.configurationURL.path,
        freezeInputs: frozen.inputs,
        freeze: frozen.context,
        limits: PageEvaluationContract.pageLimits,
        sealedOutputKey: nil,
        journal: journal,
        accumulator: &accumulator
      )
    }

    // then — a local receipt still matches, so using the local-only verifier would launch the worker.
    #expect(await launcher.observations.isEmpty)
  }

  @Test func controllerRejectsForgedResultAccounting() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "forged-accounting")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let reportedTokens = PageEvaluationContract.pageLimits.accountedTokenThreshold + 1
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
      try progress.recordUsage(
        attemptID: configuration.attemptID,
        usage: ProviderUsage(
          providerCallID: ProviderCallID(rawValue: "forged-accounting-call"),
          runId: 2,
          sessionId: 3,
          model: PageEvaluationContract.wireModel,
          promptTokens: reportedTokens,
          completionTokens: 0,
          costUSD: 0,
          costSource: .providerReturned,
          isEstimated: false,
          ts: Date(timeIntervalSince1970: 0)
        )
      )
      let forged = makeEvaluationResult(
        configuration: configuration,
        replacementDisposition: .ineligible
      )
      try EvaluationJSONFile.write(forged, to: configuration.resultURL)
      return EvaluationWorkerLaunchResult(termination: .completed, processID: 41)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: configured.configuration.evaluationRootURL,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      freezeCommit: configured.configuration.provenance.freezeCommit,
      fixedTimestamp: configured.configuration.fixedTimestamp,
      journalName: "forged-accounting.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    await #expect(throws: EvaluationControllerError.resultProgressMismatch) {
      _ = try await EvaluationController(
        launcher: launcher,
        freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context)
      ).runOne(
        executablePath: frozen.executable.path,
        configurationPath: configured.configurationURL.path,
        freezeInputs: frozen.inputs,
        freeze: frozen.context,
        limits: PageEvaluationContract.pageLimits,
        sealedOutputKey: nil,
        journal: journal,
        accumulator: &accumulator
      )
    }

    // then — the independently durable progress debit wins over a self-consistent low result.
    #expect(accumulator.responsesSends == 1)
    #expect(accumulator.accountedTokens == reportedTokens)
    #expect(accumulator.stopReason == "stage_accounted_token_threshold_crossed")
    let events = try String(
      decoding: EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url),
      as: UTF8.self
    )
    .split(separator: "\n")
    .map { try JSONDecoder().decode(EvaluationControllerJournalEvent.self, from: Data($0.utf8)) }
    let terminals = events.filter {
      $0.kind == .launchCompleted
        && $0.attemptIDs == [configured.configuration.attemptID]
    }
    #expect(terminals.count == 1)
    let terminal = try #require(terminals.first)
    #expect(terminal.observedResponsesSends == 1)
    #expect(terminal.observedFileReads == 0)
    #expect(terminal.observedAccountedTokens == reportedTokens)
  }

  @Test func rejectedWorkerSeparatesReservationFromAuthenticatedObservedProgress() async throws {
    // given
    let cases: [(attemptID: String, processID: Int32?, progress: Bool, reason: String)] = [
      ("no-start", nil, false, "worker_start_failed"),
      ("nonzero-exit", 41, true, "worker_nonzero_exit"),
    ]

    for item in cases {
      // given
      let root = try makeEvaluationTestRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let configured = try makeEvaluationConfiguration(root: root, attemptID: item.attemptID)
      let frozen = try makeEvaluationFreeze(
        root: root,
        configurations: [configured.configuration]
      )
      let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
        if item.progress {
          _ = try EvaluationAttemptProgressRecorder.start(
            invocation: invocation,
            configurations: configurations
          )
        }
        return EvaluationWorkerLaunchResult(termination: .rejected, processID: item.processID)
      }
      let journal = try EvaluationControllerJournal.startNew(
        evaluationRoot: configured.configuration.evaluationRootURL,
        manifestSHA256: configured.configuration.approval.manifestSHA256,
        freezeCommit: configured.configuration.provenance.freezeCommit,
        fixedTimestamp: configured.configuration.fixedTimestamp,
        journalName: "\(item.attemptID).jsonl"
      )
      var accumulator = EvaluationController.Accumulator()

      // when
      await #expect(throws: EvaluationPagePipelineError.invalidBatch(item.reason)) {
        _ = try await EvaluationController(
          launcher: launcher,
          freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context)
        ).runOne(
          executablePath: frozen.executable.path,
          configurationPath: configured.configurationURL.path,
          freezeInputs: frozen.inputs,
          freeze: frozen.context,
          limits: PageEvaluationContract.pageLimits,
          sealedOutputKey: nil,
          journal: journal,
          accumulator: &accumulator
        )
      }

      // then — reservation preserves the upper bound, while PID alone never fabricates observed
      // work. A worker-created zero-progress record proves the started process sent nothing.
      #expect(accumulator.responsesSends == 0)
      #expect(accumulator.fileReads == 0)
      #expect(accumulator.accountedTokens == 0)
      let events = try String(
        decoding: EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url),
        as: UTF8.self
      )
      .split(separator: "\n")
      .map { line in
        try JSONDecoder().decode(EvaluationControllerJournalEvent.self, from: Data(line.utf8))
      }
      let reservation = try #require(events.first(where: { $0.kind == .launchReserved }))
      let terminals = events.filter { $0.kind == .launchRejected }
      #expect(terminals.count == 1)
      let terminal = try #require(terminals.first)
      #expect(
        reservation.reservedResponsesSends
          == PageEvaluationContract.maximumResponsesSendsPerAttempt
      )
      #expect(terminal.observedResponsesSends == 0)
      #expect(terminal.observedFileReads == 0)
      #expect(terminal.observedAccountedTokens == 0)
      #expect(await launcher.failures.isEmpty)
    }
  }

  @Test func tamperedAttemptProgressFailsWithOneUnknownTerminalEvent() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "tampered-progress")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
      _ = try EvaluationAttemptProgressRecorder.start(
        invocation: invocation,
        configurations: configurations
      )
      let progressURL = try EvaluationAttemptProgressRecorder.url(
        invocationID: invocation.invocationID,
        configurations: configurations
      )
      var object = try #require(
        JSONSerialization.jsonObject(
          with: EvaluationPathSecurity.readRegularSingleLinkFile(at: progressURL)
        ) as? [String: Any]
      )
      object["manifest_sha256"] = String(repeating: "f", count: 64)
      try EvaluationDurablePublication.publish(
        EvaluationCanonicalJSON.data(fromJSONObject: object),
        to: progressURL
      )
      return EvaluationWorkerLaunchResult(termination: .interrupted, processID: 41)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: configured.configuration.evaluationRootURL,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      freezeCommit: configured.configuration.provenance.freezeCommit,
      fixedTimestamp: configured.configuration.fixedTimestamp,
      journalName: "tampered-progress.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    await #expect(
      throws: EvaluationPagePipelineError.invalidBatch("attempt_progress_invalid")
    ) {
      _ = try await EvaluationController(
        launcher: launcher,
        freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context)
      ).runOne(
        executablePath: frozen.executable.path,
        configurationPath: configured.configurationURL.path,
        freezeInputs: frozen.inputs,
        freeze: frozen.context,
        limits: PageEvaluationContract.pageLimits,
        sealedOutputKey: nil,
        journal: journal,
        accumulator: &accumulator
      )
    }

    // then — untrusted progress cannot debit guessed observations or emit multiple terminal rows.
    #expect(accumulator.responsesSends == 0)
    #expect(accumulator.fileReads == 0)
    #expect(accumulator.accountedTokens == 0)
    let events = try String(
      decoding: EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url),
      as: UTF8.self
    )
    .split(separator: "\n")
    .map { try JSONDecoder().decode(EvaluationControllerJournalEvent.self, from: Data($0.utf8)) }
    let terminals = events.filter {
      $0.kind == .launchInterrupted
        && $0.attemptIDs == [configured.configuration.attemptID]
    }
    #expect(terminals.count == 1)
    let terminal = try #require(terminals.first)
    #expect(terminal.observedResponsesSends == nil)
    #expect(terminal.observedFileReads == nil)
    #expect(terminal.observedAccountedTokens == nil)
  }

  @Test func postResultTokenOvershootStopsTheNextPlannedLaunch() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let originals = try ["over-budget", "must-not-launch"].enumerated().map { index, attemptID in
      try makeEvaluationConfiguration(
        root: root,
        attemptID: attemptID,
        frozenOrderIndex: index,
        frozenOrderKey: SHA256Digest.hex("order:\(attemptID)")
      )
    }
    let frozen = try makeEvaluationFreeze(
      root: root,
      configurations: originals.map(\.configuration)
    )
    let limits = PageEvaluationContract.pageLimits
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
      let configuration = try #require(configurations.first)
      let result = makeEvaluationResult(
        configuration: configuration,
        replacementDisposition: .ineligible,
        accountedTokens: limits.accountedTokenThreshold + 1
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
      journalName: "post-result-budget.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    let accepted = try await EvaluationController(
      launcher: launcher,
      freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context)
    ).executeBlocks(
      [
        EvaluationReplicateBlock(
          blockID: "budget",
          attempts: originals.map {
            EvaluationPlannedAttempt(
              configurationPath: $0.configurationURL.path,
              replacementConfigurationPath: nil
            )
          }
        )
      ],
      executablePath: frozen.executable.path,
      freezeInputs: frozen.inputs,
      freeze: frozen.context,
      limits: limits,
      sealedOutputKey: nil,
      journal: journal,
      accumulator: &accumulator
    )

    // then — the in-flight usage is kept, terminalized, and no later worker starts.
    #expect(accepted.count == 1)
    #expect(await launcher.observations.flatMap(\.attemptIDs) == ["over-budget"])
    #expect(accumulator.stopReason == "stage_accounted_token_threshold_crossed")
    #expect(accumulator.accountedTokens == limits.accountedTokenThreshold + 1)
  }
}
