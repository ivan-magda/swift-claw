import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationCanaryControllerTests {
  @Test func controllerLaunchesTwoCanaryProcessesAndStartsProcessBWithAnEmptyWorkspace()
    async throws
  {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeCanaryControllerFixture(root: root)
    let state = CanaryControllerScriptState(workspace: fixture.context.runtime.workspaceRootURL)
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, sealedKey in
      try await state.launch(
        invocation: invocation,
        configurations: configurations,
        sealedKey: sealedKey
      )
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: fixture.configurations[0].evaluationRootURL,
      manifestSHA256: fixture.configurations[0].approval.manifestSHA256,
      freezeCommit: fixture.configurations[0].provenance.freezeCommit,
      fixedTimestamp: fixture.configurations[0].fixedTimestamp,
      journalName: "canary-controller.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    let evidence = try await EvaluationController(
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

    // then
    #expect(evidence.processAUUID != evidence.processBUUID)
    #expect(await launcher.observations.count == 2)
    #expect(
      await launcher.observations.map(\.attemptIDs) == [
        ["page-canary-a-clean", "page-canary-a-nonempty"],
        ["page-canary-b-clean", "page-canary-b-nonempty"],
      ]
    )
    #expect(await state.processBWorkspaceWasEmpty)
    #expect(accumulator.attempts == 4)
    #expect(FileManager.default.fileExists(atPath: fixture.paths.canarySummary.path))
  }

  @Test func interruptedCanaryProcessAdmitsACompleteDurablePairBeforeRestart() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeCanaryControllerFixture(root: root)
    let state = CanaryControllerScriptState(
      workspace: fixture.context.runtime.workspaceRootURL,
      termination: .interrupted
    )
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, sealedKey in
      try await state.launch(
        invocation: invocation,
        configurations: configurations,
        sealedKey: sealedKey
      )
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: fixture.configurations[0].evaluationRootURL,
      manifestSHA256: fixture.configurations[0].approval.manifestSHA256,
      freezeCommit: fixture.configurations[0].provenance.freezeCommit,
      fixedTimestamp: fixture.configurations[0].fixedTimestamp,
      journalName: "canary-interrupted-complete.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    let evidence = try await EvaluationController(
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

    // then — a post-write/pre-exit signal must retain both atomic result pairs and still prove the
    // new-process lesson reload; treating interruption first would discard all four attempts.
    #expect(evidence.attemptIDs.count == PageEvaluationContract.canaryPlannedAttempts)
    #expect(
      accumulator.completedAttemptIDs.count == PageEvaluationContract.canaryPlannedAttempts
    )
    #expect(await launcher.observations.count == PageEvaluationContract.canaryProcessCount)
    let events = try String(
      decoding: try EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url),
      as: UTF8.self
    )
    .split(separator: "\n")
    .map { try JSONDecoder().decode(EvaluationControllerJournalEvent.self, from: Data($0.utf8)) }
    let terminals = events.filter { $0.kind == .launchInterrupted }
    #expect(terminals.count == PageEvaluationContract.canaryProcessCount)
    #expect(
      terminals.allSatisfy {
        $0.observedResponsesSends == PageEvaluationContract.canaryResponsesSendsPerProcess
          && $0.observedFileReads == PageEvaluationContract.canaryAttemptsPerProcess
          && $0.observedAccountedTokens == 0
      }
    )
  }

  @Test func interruptedCanaryProcessTreatsAPartialDurablePairAsIncomplete() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeCanaryControllerFixture(root: root)
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
      try EvaluationJSONFile.write(
        makeEvaluationResult(
          configuration: configuration,
          replacementDisposition: .ineligible
        ),
        to: configuration.resultURL
      )
      return EvaluationWorkerLaunchResult(termination: .interrupted, processID: 41)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: fixture.configurations[0].evaluationRootURL,
      manifestSHA256: fixture.configurations[0].approval.manifestSHA256,
      freezeCommit: fixture.configurations[0].provenance.freezeCommit,
      fixedTimestamp: fixture.configurations[0].fixedTimestamp,
      journalName: "canary-interrupted-partial.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    await #expect(
      throws: EvaluationPagePipelineError.incompleteBatch("canary_process_interrupted")
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

    // then — a normal post-first-write interruption is incomplete, never a corrupt batch or retry.
    #expect(accumulator.completedAttemptIDs.isEmpty)
    #expect(accumulator.responsesSends == 1)
    #expect(accumulator.fileReads == 0)
    #expect(accumulator.accountedTokens == PageEvaluationContract.missingUsageTokenProxy)
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
    #expect(terminal.observedAccountedTokens == PageEvaluationContract.missingUsageTokenProxy)
  }

  @Test func canaryProcessIdentityFailureRetainsTheCompletePairAccounting() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeCanaryControllerFixture(root: root)
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
      var results: [EvaluationAttemptResult] = []
      for (index, configuration) in configurations.enumerated() {
        let result = try makeCanaryEvidenceResult(
          configuration: configuration,
          processUUID: UUID(),
          sessionID: Int64(index + 1),
          lessonSetID: configuration.lessonSource == .clean ? "empty" : "candidate",
          lessonIDs: configuration.lessonSource == .clean ? [] : ["ignore-counters"],
          reportedTokensPerSend: 5
        )
        results.append(result)
        try EvaluationJSONFile.write(result, to: configuration.resultURL)
      }
      try publishEvaluationAttemptProgress(
        invocation: invocation,
        configurations: configurations,
        results: results
      )
      return EvaluationWorkerLaunchResult(termination: .completed, processID: 41)
    }
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: fixture.configurations[0].evaluationRootURL,
      manifestSHA256: fixture.configurations[0].approval.manifestSHA256,
      freezeCommit: fixture.configurations[0].provenance.freezeCommit,
      fixedTimestamp: fixture.configurations[0].fixedTimestamp,
      journalName: "canary-process-identity.jsonl"
    )
    var accumulator = EvaluationController.Accumulator()

    // when
    await #expect(
      throws: EvaluationPagePipelineError.carrierFailure("canary_process_identity")
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

    // then — process identity is a carrier verdict over a complete authenticated pair, not a reason
    // to erase the sends, reads, tokens, attempt IDs, or terminal launch evidence.
    #expect(
      accumulator.completedAttemptIDs.count == PageEvaluationContract.canaryAttemptsPerProcess
    )
    #expect(
      accumulator.responsesSends
        == PageEvaluationContract.canaryResponsesSendsPerProcess
    )
    #expect(accumulator.fileReads == PageEvaluationContract.canaryAttemptsPerProcess)
    #expect(accumulator.accountedTokens == 20)
    let events = try String(
      decoding: EvaluationPathSecurity.readRegularSingleLinkFile(at: journal.url),
      as: UTF8.self
    )
    .split(separator: "\n")
    .map { try JSONDecoder().decode(EvaluationControllerJournalEvent.self, from: Data($0.utf8)) }
    let terminals = events.filter { $0.kind == .launchCompleted }
    #expect(terminals.count == 1)
    let terminal = try #require(terminals.first)
    let reservations = events.filter { $0.kind == .launchReserved }
    #expect(reservations.count == 1)
    let reservation = try #require(reservations.first)
    let observations = await launcher.observations
    let launched = try #require(observations.first)
    #expect(terminal.attemptIDs == launched.attemptIDs)
    #expect(terminal.invocationID == reservation.invocationID)
    #expect(terminal.processID == 41)
    #expect(
      terminal.observedResponsesSends == PageEvaluationContract.canaryResponsesSendsPerProcess
    )
    #expect(terminal.observedFileReads == PageEvaluationContract.canaryAttemptsPerProcess)
    #expect(terminal.observedAccountedTokens == 20)
  }
}

private actor CanaryControllerScriptState {
  private let workspace: URL
  private let termination: EvaluationWorkerTermination
  private var launchIndex = 0
  private(set) var processBWorkspaceWasEmpty = false

  init(
    workspace: URL,
    termination: EvaluationWorkerTermination = .completed
  ) {
    self.workspace = workspace
    self.termination = termination
  }

  func launch(
    invocation: EvaluationWorkerInvocation,
    configurations: [EvaluationAttemptConfiguration],
    sealedKey: Data?
  ) throws -> EvaluationWorkerLaunchResult {
    guard configurations.count == 2, sealedKey == nil else {
      throw EvaluationHarnessTestError.unexpectedCanaryInvocation
    }
    let current = launchIndex
    launchIndex += 1
    if current == 0 {
      try EvaluationPathSecurity.ensurePrivateDirectory(at: workspace)
      try Data("process-a-stale".utf8).write(
        to: workspace.appendingPathComponent("stale.txt")
      )
    } else {
      processBWorkspaceWasEmpty = try FileManager.default
        .contentsOfDirectory(atPath: workspace.path).isEmpty
    }

    let processUUID = UUID()
    var results: [EvaluationAttemptResult] = []
    for (offset, configuration) in configurations.enumerated() {
      let hasLessons = configuration.lessonSource != .clean
      let result = try makeCanaryEvidenceResult(
        configuration: configuration,
        processUUID: processUUID,
        sessionID: Int64(current * 2 + offset + 1),
        lessonSetID: hasLessons ? "candidate" : "empty",
        lessonIDs: hasLessons ? ["ignore-counters"] : []
      )
      results.append(result)
      try EvaluationJSONFile.write(result, to: configuration.resultURL)
    }
    try publishEvaluationAttemptProgress(
      invocation: invocation,
      configurations: configurations,
      results: results
    )
    return EvaluationWorkerLaunchResult(
      termination: termination,
      processID: Int32(100 + current)
    )
  }
}
