import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationHarnessTests {
  @Test func terminalFailureMappingPreservesEveryProtocolClassAndHarnessFallback() {
    // given
    let cases: [(error: any Error, expected: EvaluationPageTerminalFailure)] = [
      (
        EvaluationPagePipelineError.invalidBatch("invalid"),
        EvaluationPageTerminalFailure(classification: .invalidBatch, reason: "invalid")
      ),
      (
        EvaluationPagePipelineError.carrierFailure("carrier"),
        EvaluationPageTerminalFailure(classification: .carrierFailure, reason: "carrier")
      ),
      (
        EvaluationPagePipelineError.safetyFailure("safety"),
        EvaluationPageTerminalFailure(classification: .safetyFailure, reason: "safety")
      ),
      (
        EvaluationPagePipelineError.taskSpecificFailure("task"),
        EvaluationPageTerminalFailure(
          classification: .pageTaskSpecificFailure,
          reason: "task"
        )
      ),
      (
        EvaluationPagePipelineError.incompleteBatch("incomplete"),
        EvaluationPageTerminalFailure(
          classification: .incompleteBatch,
          reason: "incomplete"
        )
      ),
      (
        EvaluationPagePipelineError.canaryEvidenceMissing,
        EvaluationPageTerminalFailure(
          classification: .carrierFailure,
          reason: "canary_carrier_evidence_missing"
        )
      ),
      (
        EvaluationWorkspaceError.invalidActiveLessonPointer,
        EvaluationPageTerminalFailure(
          classification: .carrierFailure,
          reason: EvaluationWorkspaceFailureReason.invalidActiveLessonPointer.rawValue
        )
      ),
      (
        EvaluationWorkspaceError.immutableLessonCollision("lesson.json"),
        EvaluationPageTerminalFailure(
          classification: .invalidBatch,
          reason: EvaluationWorkspaceFailureReason.immutableLessonCollision.rawValue
        )
      ),
      (
        CancellationError(),
        EvaluationPageTerminalFailure(
          classification: .incompleteBatch,
          reason: "controller_cancelled"
        )
      ),
      (
        EvaluationPathSecurityError.insecureFile("input.json"),
        EvaluationPageTerminalFailure(
          classification: .invalidBatch,
          reason: "evaluation_path_integrity_failure"
        )
      ),
      (
        EvaluationHarnessTestError.unexpectedCanaryInvocation,
        EvaluationPageTerminalFailure(
          classification: .invalidBatch,
          reason: "unclassified_harness_failure"
        )
      ),
    ]

    // when
    let observed = cases.map { EvaluationPageExperiment.terminalFailure(for: $0.error) }

    // then
    #expect(observed == cases.map(\.expected))
  }

  @Test func toolContractClassifiesEachFrozenDimension() {
    // given
    let valid = EvaluationToolRecord(
      name: EvaluationToolContract.requiredToolName,
      path: PageEvaluationContract.inputFileName,
      status: EvaluationToolContract.succeededStatus
    )
    let cases: [(records: [EvaluationToolRecord], violation: EvaluationToolViolation?)] = [
      ([], .expectedOneFileRead),
      ([valid, valid], .expectedOneFileRead),
      (
        [
          EvaluationToolRecord(
            name: "web_fetch",
            path: nil,
            status: EvaluationToolContract.succeededStatus
          )
        ],
        .unexpectedTool
      ),
      (
        [
          EvaluationToolRecord(
            name: EvaluationToolContract.requiredToolName,
            path: "other.json",
            status: EvaluationToolContract.succeededStatus
          )
        ],
        .unexpectedFileReadPath
      ),
      (
        [
          EvaluationToolRecord(
            name: EvaluationToolContract.requiredToolName,
            path: PageEvaluationContract.inputFileName,
            status: EvaluationToolContract.failedStatus
          )
        ],
        .fileReadFailed
      ),
      ([valid], nil),
    ]

    // when
    let observed = cases.map {
      EvaluationToolContract.violation(in: $0.records)
    }

    // then — each field owns a distinct branch; deleting or reordering any guard changes its
    // externally persisted critical code.
    #expect(observed == cases.map(\.violation))
  }

  @Test func canonicalJSONMatchesTheCrossLanguageFreezeVector() throws {
    // given
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let vectorURL = repositoryRoot.appendingPathComponent(
      "experiments/scheduled-task-learning/page-change/contracts/canonical-json-vector.json"
    )
    let vector = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL)) as? [String: Any]
    )
    let value = try #require(vector["value"])
    let expected = try #require(vector["canonical_json"] as? String)
    let expectedSHA256 = try #require(vector["canonical_sha256"] as? String)

    // when
    let encoded = try EvaluationCanonicalJSON.data(fromJSONObject: value)

    // then
    #expect(encoded == Data(expected.utf8))
    #expect(SHA256Digest.hex(encoded) == expectedSHA256)
  }

  @Test func approvalBindingRejectsAHostPrefixLookalike() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(
      root: root,
      approvalURL:
        "https://github.com.evil.invalid/ivan-magda/swift-claw/issues/118#issuecomment-5423356186"
    )

    // when
    let error = #expect(throws: EvaluationConfigurationError.invalidApprovalURL) {
      try configured.configuration.validate()
    }

    // then
    #expect(error != nil)
  }

  @Test func rawRelativePathsAreRejectedBeforeFoundationCanNormalizeThem() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    var configurationObject = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(configured.configuration)
      ) as? [String: Any]
    )
    configurationObject["source_artifact_path"] = "relative/source.json"
    let relativeConfiguration = try JSONDecoder().decode(
      EvaluationAttemptConfiguration.self,
      from: JSONSerialization.data(withJSONObject: configurationObject)
    )

    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: configured.configuration.evaluationRootURL,
      manifestSHA256: configured.configuration.approval.manifestSHA256,
      freezeCommit: configured.configuration.provenance.freezeCommit,
      fixedTimestamp: configured.configuration.fixedTimestamp,
      journalName: "relative-path.jsonl"
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
    var invocationObject = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: URL(fileURLWithPath: written.path))
      ) as? [String: Any]
    )
    invocationObject["configuration_path"] = "relative/configuration.json"
    let relativeInvocation = try JSONDecoder().decode(
      EvaluationWorkerInvocation.self,
      from: JSONSerialization.data(withJSONObject: invocationObject)
    )

    // when
    let configurationError = #expect(throws: EvaluationConfigurationError.pathsMustBeAbsolute) {
      try relativeConfiguration.validate()
    }
    let invocationError = #expect(throws: EvaluationWorkerInvocationError.invalidInvocation) {
      try relativeInvocation.validate()
    }

    // then — URL(fileURLWithPath:) would normalize both strings against the cwd.
    #expect(configurationError != nil)
    #expect(invocationError != nil)
  }

  @Test func configurationRejectsUnknownAndMismatchedStageVocabulary() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let encoded = try JSONEncoder().encode(configured.configuration)
    let original = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let mutations: [(key: String, value: String)] = [
      ("stage", "development-typo"),
      ("split", "regression"),
    ]

    // when
    let errors = try mutations.map { mutation in
      var object = original
      object[mutation.key] = mutation.value
      let candidate = try JSONDecoder().decode(
        EvaluationAttemptConfiguration.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
      return #expect(throws: EvaluationConfigurationError.invalidStageTopology) {
        try candidate.validate()
      }
    }

    // then — mutants that accept raw strings or validate stage/split independently miss a case.
    #expect(errors.allSatisfy { $0 != nil })
  }

  @Test func workspaceResetLeavesOnlyTheVerifiedInput() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    try FileManager.default.createDirectory(
      at: configured.configuration.workspaceRootURL,
      withIntermediateDirectories: true
    )
    try Data("stale".utf8).write(
      to: configured.configuration.workspaceRootURL.appendingPathComponent("stale.txt")
    )

    // when
    let materialized = try EvaluationWorkspaceMaterializer.reset(
      configuration: configured.configuration
    )

    // then
    #expect(materialized.inputSHA256 == configured.configuration.inputSHA256)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: configured.configuration.workspaceRootURL.path
      ) == [PageEvaluationContract.inputFileName]
    )
  }

  @Test func publishedLessonArtifactIsReloadedIntoAFreshWorkspaceMaterialization() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configurations = try makeEvaluationLessonReloadConfigurations(root: root)

    // when
    let first = try EvaluationWorkspaceMaterializer.reset(
      configuration: configurations.artifact
    )
    let stale = configurations.artifact.workspaceRootURL.appendingPathComponent("stale.txt")
    try Data("stale".utf8).write(to: stale)
    let restarted = try EvaluationWorkspaceMaterializer.reset(
      configuration: configurations.durable
    )

    // then
    #expect(first.lessonSetDigest == restarted.lessonSetDigest)
    #expect(first.lessonSetID == "candidate")
    #expect(restarted.lessonIDs == ["ignore-counters"])
    #expect(first.inputSHA256 == restarted.inputSHA256)
    #expect(restarted.lessonSource == .durableActive)
    #expect(restarted.lessonSetPath?.contains("/state/lesson-sets/") == true)
    #expect(FileManager.default.fileExists(atPath: stale.path) == false)
  }

  @Test(arguments: ["active-pointer", "immutable-artifact"])
  func durableLessonReloadRejectsMutatedSelectionEvidence(_ mutation: String) throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configurations = try makeEvaluationLessonReloadConfigurations(root: root)
    let published = try EvaluationWorkspaceMaterializer.reset(
      configuration: configurations.artifact
    )
    let stateRoot = configurations.artifact.stateRootURL
    switch mutation {
    case "active-pointer":
      try Data(#"{"schema_version":1}"#.utf8).write(
        to: stateRoot.appendingPathComponent(PageEvaluationContract.activeLessonFileName)
      )
    case "immutable-artifact":
      let immutable =
        stateRoot
        .appendingPathComponent(PageEvaluationContract.lessonSetsDirectoryName, isDirectory: true)
        .appendingPathComponent("\(published.lessonSetDigest).json")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: immutable.path
      )
      try Data("tampered".utf8).write(to: immutable)
    default:
      Issue.record("Unknown mutation \(mutation)")
    }

    // when
    let error = #expect(throws: EvaluationWorkspaceError.self) {
      _ = try EvaluationWorkspaceMaterializer.reset(configuration: configurations.durable)
    }

    // then — a fresh materialization must revalidate both layers from durable storage.
    #expect(error != nil)
  }

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

  @Test func uncertainEvaluationPublicationSurfacesAfterTheCommittedNameCannotBeSynced() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("receipt.json")
    let intended = Data("durable-receipt".utf8)
    let publisher = SecureFilePublisher(
      failpoint: SecureFilePublisher.Failpoint(.directorySync, on: destination.lastPathComponent)
    )

    // when
    let error = #expect(
      throws: EvaluationDurablePublicationError.commitUncertain(destination.lastPathComponent)
    ) {
      try EvaluationDurablePublication.publish(intended, to: destination, publisher: publisher)
    }

    // then — the target name landed, but the harness refuses to report a durable write.
    #expect(error != nil)
    #expect(try Data(contentsOf: destination) == intended)
  }

  @Test func workerLifecycleOwnsTheProductionLockAndShutsDownInOrder() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state")
    let events = LifecycleEvents()

    // when
    let value = try await EvaluationWorkerLifecycle.withProductionLock(
      stateRoot: stateRoot,
      makeResource: {
        let lockPath = stateRoot.appendingPathComponent("clawd.lock").path
        do {
          let unexpected = try InstanceLock(path: lockPath)
          unexpected.release()
          await events.append("resource_without_lock")
        } catch InstanceLock.LockError.alreadyLocked {
          await events.append("resource_under_lock")
        }
        return RecordingLifecycleResource(events: events)
      },
      operation: { _, _ in
        await events.append("operation")
        return 7
      }
    )
    let reacquired = try InstanceLock(path: stateRoot.appendingPathComponent("clawd.lock").path)
    reacquired.release()

    // then
    #expect(value == 7)
    #expect(
      await events.values
        == ["resource_under_lock", "operation", "credentials_closed", "transport_closed"]
    )
  }

  @Test func operationAndCredentialShutdownFailureStillClosesTransportAndFailsIntegrity() async {
    // given
    let events = LifecycleEvents()

    // when
    let error = await #expect(throws: EvaluationWorkerLifecycleError.self) {
      _ = try await EvaluationWorkerLifecycle.withResource(
        makeResource: { FailingLifecycleResource(events: events) },
        operation: { _ -> Int in
          await events.append("operation_failed")
          throw LifecycleTestError.operation
        }
      )
    }

    // then
    #expect(error != nil)
    #expect(
      await events.values
        == ["operation_failed", "credentials_failed", "transport_closed"]
    )
  }

  @Test func wireModelRefusalDoesNotCountAsAnOutboundSend() async throws {
    // given
    let recorder = EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))
    let request = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: Data(#"{"model":"wrong-model"}"#.utf8),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 100, errorBytes: 100)
    )

    // when
    await #expect(throws: EvaluationHTTPError.wireModelMismatch) {
      _ = try await recorder.openStream(request)
    }
    let snapshot = await recorder.snapshot()

    // then
    #expect(snapshot.responsesSends.isEmpty)
    #expect(snapshot.integrityFailures == ["wire_model_mismatch"])
  }

  @Test func responsesInferenceCannotEvadeStreamingAccountingViaBufferedExecute() async {
    // given
    let recorder = EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))
    let request = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: Data(#"{"model":"gpt-5.6-sol"}"#.utf8),
      timeout: .seconds(1),
      responseBodyPolicy: .buffered(successBytes: 1_024, errorBytes: 1_024)
    )

    // when
    await #expect(throws: EvaluationHTTPError.bufferedInferenceForbidden) {
      _ = try await recorder.execute(request)
    }
    let snapshot = await recorder.snapshot()

    // then
    #expect(snapshot.responsesSends.isEmpty)
    #expect(snapshot.credentialHTTPCalls == 0)
    #expect(snapshot.integrityFailures == ["buffered_inference_forbidden"])
  }

  @Test func streamingCannotLeaveTheFrozenResponsesEndpoint() async {
    // given
    let base = ScriptedHTTPExecutor([])
    let recorder = EvaluationHTTPRecorder(base: base)
    let request = HTTPRequest(
      method: .post,
      url: "https://example.invalid/not-responses",
      headers: [:],
      body: Data(#"{"model":"gpt-5.6-sol"}"#.utf8),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 100, errorBytes: 100)
    )

    // when
    let error = await #expect(throws: EvaluationHTTPError.unexpectedStreamEndpoint) {
      _ = try await recorder.openStream(request)
    }
    let snapshot = await recorder.snapshot()

    // then
    #expect(error != nil)
    #expect(snapshot.responsesSends.isEmpty)
    #expect(snapshot.credentialHTTPCalls == 0)
    #expect(snapshot.integrityFailures == ["unexpected_stream_endpoint"])
    #expect(await base.recorded.isEmpty)
  }

  @Test func accountedTokensSaturateInsteadOfTrappingOnProviderExtremes() {
    // given
    let usage = ProviderUsage(
      providerCallID: ProviderCallID(rawValue: "extreme"),
      runId: 1,
      sessionId: 1,
      model: PageEvaluationContract.wireModel,
      promptTokens: .max,
      completionTokens: .max,
      costUSD: 0,
      costSource: .providerReturned,
      isEstimated: false,
      ts: Date(timeIntervalSince1970: 0)
    )

    // when
    let accounted = EvaluationResultAccounting.accountedTokens(
      responsesSends: PageEvaluationContract.maximumResponsesSendsPerAttempt,
      usage: [usage]
    )
    let estimatedAccounted = EvaluationResultAccounting.accountedTokens(
      responsesSends: 1,
      usage: [
        ProviderUsage(
          providerCallID: ProviderCallID(rawValue: "estimated"),
          runId: 1,
          sessionId: 1,
          model: PageEvaluationContract.wireModel,
          promptTokens: 1,
          completionTokens: 0,
          costUSD: 0,
          costSource: .heuristic,
          isEstimated: true,
          ts: Date(timeIntervalSince1970: 0)
        )
      ]
    )
    let recorded = EvaluationUsageRecord(usage).totalTokens

    // then
    #expect(accounted == .max)
    #expect(estimatedAccounted == PageEvaluationContract.missingUsageTokenProxy)
    #expect(recorded == .max)
  }

  @Test func attemptProgressRejectsEveryIndependentIdentityAndAccountingMutation() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let configuration = configured.configuration
    let second = try makeEvaluationReplacement(
      of: configuration,
      configurationDirectory: root.appendingPathComponent("artifacts", isDirectory: true)
    ).configuration
    let configurations = [configuration, second]
    let invocationID = UUID()
    let invocationConfigurationSHA256 = String(repeating: "a", count: 64)
    let usage = EvaluationUsageRecord(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "progress-validation"),
        runId: 2,
        sessionId: 3,
        model: PageEvaluationContract.wireModel,
        promptTokens: 37,
        completionTokens: 0,
        costUSD: 0,
        costSource: .providerReturned,
        isEstimated: false,
        ts: Date(timeIntervalSince1970: 0)
      )
    )
    let valid = EvaluationAttemptProgressRecord(
      schemaVersion: PageEvaluationContract.schemaVersion,
      invocationID: invocationID,
      invocationConfigurationSHA256: invocationConfigurationSHA256,
      manifestSHA256: configuration.approval.manifestSHA256,
      attempts: [
        EvaluationAttemptProgressEntry(
          attemptID: configuration.attemptID,
          configurationSHA256: try EvaluationAttemptProgressRecord.configurationSHA256(
            configuration
          ),
          responsesRequests: [makeEvaluationResponsesSend(sequence: 1)],
          provenNotStartedResponsesSends: 0,
          credentialHTTPCalls: 0,
          fileReads: 0,
          accountedTokens: 37,
          usage: [usage]
        ),
        EvaluationAttemptProgressEntry(
          attemptID: second.attemptID,
          configurationSHA256: try EvaluationAttemptProgressRecord.configurationSHA256(second),
          responsesRequests: [],
          provenNotStartedResponsesSends: 0,
          credentialHTTPCalls: 0,
          fileReads: 0,
          accountedTokens: 0,
          usage: []
        ),
      ]
    )
    typealias Mutation = (inout [String: Any]) throws -> Void
    func mutateEntry(
      _ object: inout [String: Any],
      _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
      var attempts = try #require(object["attempts"] as? [[String: Any]])
      try mutation(&attempts[0])
      object["attempts"] = attempts
    }
    let mutations: [(String, Mutation)] = [
      ("schema", { $0["schema_version"] = PageEvaluationContract.schemaVersion + 1 }),
      ("invocation", { $0["invocation_id"] = UUID().uuidString.lowercased() }),
      (
        "invocation config",
        {
          $0["invocation_configuration_sha256"] = String(repeating: "b", count: 64)
        }
      ),
      ("manifest", { $0["manifest_sha256"] = String(repeating: "c", count: 64) }),
      (
        "attempt",
        { object in
          try mutateEntry(&object) { $0["attempt_id"] = "other-attempt" }
        }
      ),
      (
        "attempt ID order",
        { object in
          var attempts = try #require(object["attempts"] as? [[String: Any]])
          let first = try #require(attempts[0]["attempt_id"] as? String)
          let second = try #require(attempts[1]["attempt_id"] as? String)
          attempts[0]["attempt_id"] = second
          attempts[1]["attempt_id"] = first
          object["attempts"] = attempts
        }
      ),
      (
        "attempt config",
        { object in
          try mutateEntry(&object) {
            $0["configuration_sha256"] = String(repeating: "d", count: 64)
          }
        }
      ),
      (
        "configuration hash order",
        { object in
          var attempts = try #require(object["attempts"] as? [[String: Any]])
          let first = try #require(attempts[0]["configuration_sha256"] as? String)
          let second = try #require(attempts[1]["configuration_sha256"] as? String)
          attempts[0]["configuration_sha256"] = second
          attempts[1]["configuration_sha256"] = first
          object["attempts"] = attempts
        }
      ),
      (
        "send cap",
        { object in
          try mutateEntry(&object) { entry in
            let request = try #require(
              (entry["responses_requests"] as? [[String: Any]])?.first
            )
            entry["responses_requests"] = [request, request, request]
          }
        }
      ),
      (
        "file-read cap",
        { object in
          try mutateEntry(&object) {
            $0["file_reads"] = PageEvaluationContract.runBudget.maxToolCalls + 1
          }
        }
      ),
      (
        "negative file-read",
        { object in
          try mutateEntry(&object) { $0["file_reads"] = -1 }
        }
      ),
      (
        "credential calls",
        { object in
          try mutateEntry(&object) { $0["credential_http_calls"] = -1 }
        }
      ),
      (
        "negative no-start",
        { object in
          try mutateEntry(&object) { $0["proven_not_started_responses_sends"] = -1 }
        }
      ),
      (
        "no-start plus usage",
        { object in
          try mutateEntry(&object) {
            $0["proven_not_started_responses_sends"] = 1
            $0["accounted_tokens"] = 0
          }
        }
      ),
      (
        "negative usage",
        { object in
          try mutateEntry(&object) { entry in
            var rows = try #require(entry["usage"] as? [[String: Any]])
            rows[0]["prompt_tokens"] = -1
            rows[0]["total_tokens"] = -1
            entry["usage"] = rows
            entry["accounted_tokens"] = 0
          }
        }
      ),
      (
        "negative completion usage",
        { object in
          try mutateEntry(&object) { entry in
            var rows = try #require(entry["usage"] as? [[String: Any]])
            rows[0]["prompt_tokens"] = 0
            rows[0]["completion_tokens"] = -1
            rows[0]["total_tokens"] = -1
            entry["usage"] = rows
            entry["accounted_tokens"] = 0
          }
        }
      ),
      (
        "usage sum",
        { object in
          try mutateEntry(&object) { entry in
            var rows = try #require(entry["usage"] as? [[String: Any]])
            rows[0]["total_tokens"] = 36
            entry["usage"] = rows
            entry["accounted_tokens"] = 36
          }
        }
      ),
      (
        "duplicate provider call",
        { object in
          try mutateEntry(&object) { entry in
            let request = try #require(
              (entry["responses_requests"] as? [[String: Any]])?.first
            )
            let row = try #require((entry["usage"] as? [[String: Any]])?.first)
            entry["responses_requests"] = [request, request]
            entry["usage"] = [row, row]
            entry["accounted_tokens"] = 74
          }
        }
      ),
      (
        "accounted total",
        { object in
          try mutateEntry(&object) { $0["accounted_tokens"] = 36 }
        }
      ),
    ]
    let base = try #require(
      JSONSerialization.jsonObject(with: EvaluationCanonicalJSON.data(encoding: valid))
        as? [String: Any]
    )

    // when
    try valid.validate(
      invocationID: invocationID,
      invocationConfigurationSHA256: invocationConfigurationSHA256,
      configurations: configurations
    )

    // then — every mutation kills a distinct fail-closed ledger guard.
    for (_, mutation) in mutations {
      var object = base
      try mutation(&object)
      let record = try JSONDecoder().decode(
        EvaluationAttemptProgressRecord.self,
        from: EvaluationCanonicalJSON.data(fromJSONObject: object)
      )
      #expect(throws: EvaluationPagePipelineError.invalidBatch("attempt_progress_identity")) {
        try record.validate(
          invocationID: invocationID,
          invocationConfigurationSHA256: invocationConfigurationSHA256,
          configurations: configurations
        )
      }
    }
  }

  @Test func structuralHashNormalizesOnlyProtocolDeclaredEphemeralValues() throws {
    // given
    let firstFence =
      #"<claw-untrusted nonce="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" label="file_read">x</claw-untrusted nonce="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">"#
    let secondFence =
      #"<claw-untrusted nonce="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" label="file_read">x</claw-untrusted nonce="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">"#
    let firstBody = try JSONSerialization.data(
      withJSONObject: ["model": PageEvaluationContract.wireModel, "input": firstFence]
    )
    let secondBody = try JSONSerialization.data(
      withJSONObject: ["model": PageEvaluationContract.wireModel, "input": secondFence]
    )
    let ordinaryA = try JSONSerialization.data(
      withJSONObject: [
        "model": PageEvaluationContract.wireModel,
        "input": #"ordinary nonce="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" text"#,
      ]
    )
    let ordinaryB = try JSONSerialization.data(
      withJSONObject: [
        "model": PageEvaluationContract.wireModel,
        "input": #"ordinary nonce="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" text"#,
      ]
    )
    func secondRequest(
      callID: String,
      reasoning: String,
      path: String,
      fence: String,
      assistantText: String? = nil
    ) throws
      -> Data
    {
      let assistantReplay: [[String: Any]] =
        assistantText.map { text in
          [
            [
              "content": [["text": text, "type": "output_text"]],
              "role": "assistant",
              "status": "completed",
              "type": "message",
            ]
          ]
        } ?? []
      return try JSONSerialization.data(withJSONObject: [
        "input": assistantReplay + [
          [
            "encrypted_content": reasoning,
            "summary": ["provider-generated summary"],
            "type": "reasoning",
          ],
          [
            "arguments": #"{"path":"\#(path)"}"#,
            "call_id": callID,
            "name": "file_read",
            "type": "function_call",
          ],
          [
            "call_id": callID,
            "output": fence,
            "type": "function_call_output",
          ],
        ],
        "model": PageEvaluationContract.wireModel,
      ])
    }
    let replayA = try secondRequest(
      callID: "call-provider-a",
      reasoning: "encrypted-provider-a",
      path: "input.json",
      fence: firstFence,
      assistantText: "I will read the approved input."
    )
    let replayB = try secondRequest(
      callID: "call-provider-a",
      reasoning: "encrypted-provider-a",
      path: "input.json",
      fence: secondFence,
      assistantText: "I will read the approved input."
    )
    let callIDDrift = try secondRequest(
      callID: "call-provider-b",
      reasoning: "encrypted-provider-a",
      path: "input.json",
      fence: secondFence,
      assistantText: "I will read the approved input."
    )
    let reasoningDrift = try secondRequest(
      callID: "call-provider-a",
      reasoning: "encrypted-provider-b",
      path: "input.json",
      fence: secondFence,
      assistantText: "I will read the approved input."
    )
    let assistantDrift = try secondRequest(
      callID: "call-provider-a",
      reasoning: "encrypted-provider-a",
      path: "input.json",
      fence: secondFence,
      assistantText: "Different visible commentary."
    )
    let pathDrift = try secondRequest(
      callID: "call-provider-a",
      reasoning: "encrypted-provider-a",
      path: "other.json",
      fence: secondFence,
      assistantText: "I will read the approved input."
    )

    // when
    let firstFenceHash = EvaluationHTTPRecorder.normalizedStructureSHA256(firstBody)
    let secondFenceHash = EvaluationHTTPRecorder.normalizedStructureSHA256(secondBody)
    let replayHash = EvaluationHTTPRecorder.normalizedStructureSHA256(replayA)
    let replayBHash = EvaluationHTTPRecorder.normalizedStructureSHA256(replayB)

    // then
    #expect(firstFenceHash == secondFenceHash)
    #expect(
      EvaluationHTTPRecorder.normalizedStructureSHA256(ordinaryA)
        != EvaluationHTTPRecorder.normalizedStructureSHA256(ordinaryB)
    )
    #expect(replayHash == replayBHash)
    #expect(replayBHash != EvaluationHTTPRecorder.normalizedStructureSHA256(callIDDrift))
    #expect(replayBHash != EvaluationHTTPRecorder.normalizedStructureSHA256(reasoningDrift))
    #expect(replayBHash != EvaluationHTTPRecorder.normalizedStructureSHA256(assistantDrift))
    #expect(replayBHash != EvaluationHTTPRecorder.normalizedStructureSHA256(pathDrift))
  }

  @Test func recorderSeparatesCredentialTrafficAndBindsTheExactFencedCarrierAtItsCap() async throws
  {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "http-progress")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let budget = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
      stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
    )
    let progressFixture = try startEvaluationAttemptProgress(
      configuration: configured.configuration,
      configurationURL: configured.configurationURL,
      freezeInputs: frozen.inputs,
      budget: budget,
      journalName: "http-progress.jsonl"
    )
    let head = HTTPStreamHead(statusCode: 200, headers: [:])
    let http = ScriptedHTTPExecutor([
      .ok(HTTPResult(statusCode: 200, headers: [:], body: Data())),
      .stream(head, []),
      .stream(head, []),
    ])
    let recorder = EvaluationHTTPRecorder(
      base: http,
      maximumResponsesSends: PageEvaluationContract.maximumResponsesSendsPerAttempt,
      progressRecorder: progressFixture.recorder,
      attemptID: configured.configuration.attemptID
    )
    let credential = HTTPRequest(
      method: .post,
      url: "https://auth.openai.com/oauth/token",
      headers: [:],
      body: Data(),
      timeout: .seconds(1),
      responseBodyPolicy: .buffered(successBytes: 1_024, errorBytes: 1_024)
    )
    let carrier = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "active_lessons": ["lesson_set_id": "empty", "lessons": [], "schema_version": 1],
      "schema_version": 1,
      "task": [:],
      "task_id": "page-000000000001",
    ])
    let fenced = LabeledContext(
      label: "file_read",
      content: String(decoding: carrier, as: UTF8.self),
      nonce: String(repeating: "a", count: 32)
    ).render()
    func responsesRequest(input: String) throws -> HTTPRequest {
      HTTPRequest(
        method: .post,
        url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
        headers: [:],
        body: try JSONSerialization.data(withJSONObject: [
          "input": input, "model": PageEvaluationContract.wireModel,
        ]),
        timeout: .seconds(1),
        responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
      )
    }

    // when
    _ = try await recorder.execute(credential)
    _ = try await recorder.openStream(responsesRequest(input: "read input.json"))
    _ = try await recorder.openStream(responsesRequest(input: fenced))
    await #expect(throws: EvaluationHTTPError.responsesSendCap) {
      _ = try await recorder.openStream(responsesRequest(input: fenced))
    }
    let snapshot = await recorder.snapshot()
    let progress = try #require(
      try EvaluationAttemptProgressRecorder.loadIfPresent(
        invocationID: progressFixture.invocation.invocationID,
        invocationConfigurationSHA256: progressFixture.invocation.configurationSHA256,
        configurations: [configured.configuration]
      )
    )

    // then — OAuth is not an inference send, but both credential and safe request metadata are
    // durably forwarded before their respective transport boundaries.
    #expect(snapshot.credentialHTTPCalls == 1)
    #expect(snapshot.responsesSends.map(\.sequence) == [1, 2])
    #expect(snapshot.responsesSends[0].untrustedPayloadSHA256 == nil)
    #expect(snapshot.responsesSends[1].untrustedPayloadSHA256 == SHA256Digest.hex(carrier))
    #expect(snapshot.integrityFailures == ["responses_send_cap"])
    #expect(await http.recorded.count == 3)
    #expect(progress.attempts.first?.credentialHTTPCalls == 1)
    #expect(progress.attempts.first?.responsesRequests == snapshot.responsesSends)
    #expect(progress.attempts.first?.responsesSends == 2)
  }

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

  @Test func publicPageSeamRejectsMutatedRunOrderBeforeAnyExecutableBoundary() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let manifest = EvaluationFreezeManifest(
      schemaVersion: PageEvaluationContract.schemaVersion,
      decision: "D6",
      experiment: "page-change",
      protocolBinding: frozen.context.manifest.protocolBinding,
      categories: frozen.context.manifest.categories,
      protectedArtifacts: frozen.context.manifest.protectedArtifacts
    )
    let context = EvaluationFreezeContext(
      repositoryRoot: frozen.context.repositoryRoot,
      manifest: manifest,
      receipt: frozen.context.receipt,
      runtime: frozen.context.runtime,
      runOrderJSON: Data(#"{"schema_version":2,"stages":[]}"#.utf8)
    )
    let inputsURL = root.appendingPathComponent("freeze-inputs.json")
    try EvaluationJSONFile.write(frozen.inputs, to: inputsURL)
    let artifacts = ScriptedEvaluationProtectedArtifactRunner(output: Data())
    let launcher = ScriptedEvaluationWorkerLauncher { _, _, _ in
      EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
    let experiment = EvaluationPageExperiment(
      freezeVerifier: StaticEvaluationFreezeVerifier(context: context),
      artifacts: artifacts,
      launcher: launcher
    )

    // when
    let error = await #expect(throws: EvaluationPagePipelineError.invalidRunOrder) {
      _ = try await experiment.run(freezeInputsPath: inputsURL.path)
    }

    // then
    #expect(error != nil)
    #expect(await artifacts.invocations.isEmpty)
    #expect(await launcher.observations.isEmpty)
    let paths = EvaluationController.PagePipelinePaths(
      evaluationRoot: configured.configuration.evaluationRootURL
    )
    let result = try EvaluationJSONFile.decode(
      EvaluationPagePipelineResult.self,
      from: paths.result
    )
    #expect(result.outcome == EvaluationPageTerminalClassification.invalidBatch.rawValue)
    #expect(result.incomplete == false)
    #expect(result.stopReason == "invalid_run_order")
    let journalURL = configured.configuration.evaluationRootURL
      .appendingPathComponent("journal", isDirectory: true)
      .appendingPathComponent(
        "page-\(configured.configuration.approval.manifestSHA256).jsonl",
        isDirectory: false
      )
    #expect(
      result.journalSHA256
        == SHA256Digest.hex(try EvaluationPathSecurity.readRegularSingleLinkFile(at: journalURL))
    )
  }

  @Test func taskStageProjectionRejectsAReorderedFrozenAttempt() throws {
    // given
    var slots: [EvaluationPageTaskSlot] = []
    for fixture in 1...6 {
      for replicate in 1...3 {
        let index = slots.count
        slots.append(
          EvaluationPageTaskSlot(
            stage: "development",
            split: "development",
            orderIndex: index,
            blockIndex: index,
            orderKey: SHA256Digest.hex("attempt:\(index)"),
            blockOrderKey: SHA256Digest.hex("block:\(index)"),
            fixtureID: String(format: "pc-development-%02d", fixture),
            replicate: replicate,
            condition: "clean",
            lessonSource: .clean,
            workerProcessKey: SHA256Digest.hex("worker:\(index)")
          )
        )
      }
    }
    try EvaluationPageRunOrder.validateTaskStage(
      name: "development",
      split: "development",
      counterbalancePhase: nil,
      slots: slots
    )
    slots.swapAt(0, 1)

    // when
    let error = #expect(throws: EvaluationPagePipelineError.invalidRunOrder) {
      try EvaluationPageRunOrder.validateTaskStage(
        name: "development",
        split: "development",
        counterbalancePhase: nil,
        slots: slots
      )
    }

    // then — counts and identities still match; only the approved sequence changed.
    #expect(error != nil)
  }

  @Test func barrierProjectionRejectsASemanticSubstitution() {
    // given
    var barriers = [
      EvaluationPageBarrierSlot(
        name: "lesson-freeze-barrier",
        barrier: "freeze-one-semantic-lesson-set-before-regression",
        orderKey: SHA256Digest.hex("barrier:0")
      ),
      EvaluationPageBarrierSlot(
        name: "regression-unseal-barrier",
        barrier: "jointly-unseal-both-regression-conditions-and-apply-admission-gate",
        orderKey: SHA256Digest.hex("barrier:1")
      ),
      EvaluationPageBarrierSlot(
        name: "sealed-full-process-restart-barrier",
        barrier: "publish-flush-exit-release-lock-and-start-new-os-process",
        orderKey: SHA256Digest.hex("barrier:2")
      ),
      EvaluationPageBarrierSlot(
        name: "sealed-joint-unseal-barrier",
        barrier: "jointly-unseal-clean-lesson-and-post-restart-sealed-conditions",
        orderKey: SHA256Digest.hex("barrier:3")
      ),
    ]
    #expect(EvaluationPageRunOrder.validateBarriers(barriers))

    // when
    barriers[2] = EvaluationPageBarrierSlot(
      name: barriers[2].name,
      barrier: "restart-workers-later",
      orderKey: barriers[2].orderKey
    )

    // then — names, order and digests still match; only the frozen operation changed.
    #expect(!EvaluationPageRunOrder.validateBarriers(barriers))
  }

  @Test func replacementConfigurationAllowsExactlyFourLineageFieldsToChange() throws {
    // given
    #expect(
      EvaluationAttemptConfiguration.replacementLineageCodingKeys
        == Set([
          .attemptID, .resultPath, .replacementOfAttemptID, .replacementOrdinal,
        ])
    )
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try makeEvaluationConfiguration(root: root, attemptID: "lineage")
    let replacement = try makeEvaluationReplacement(
      of: original.configuration,
      configurationDirectory: root.appendingPathComponent("artifacts", isDirectory: true)
    )
    try EvaluationController.validateReplacement(
      at: replacement.configurationURL.path,
      of: original.configurationURL.path
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: replacement.configurationURL))
        as? [String: Any]
    )
    object[EvaluationAttemptConfiguration.CodingKeys.fixtureID.rawValue] = "pc-development-02"
    try EvaluationDurablePublication.publish(
      EvaluationCanonicalJSON.data(fromJSONObject: object),
      to: replacement.configurationURL
    )

    // when
    let error = #expect(throws: EvaluationControllerError.replacementLineageMismatch) {
      try EvaluationController.validateReplacement(
        at: replacement.configurationURL.path,
        of: original.configurationURL.path
      )
    }

    // then
    #expect(error != nil)
  }

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

  @Test func authenticatedWorkspaceFailureEvidencePreservesCarrierVersusInvalidClassification()
    async throws
  {
    // given
    let cases:
      [(
        attemptID: String,
        error: EvaluationWorkspaceError,
        expected: EvaluationPagePipelineError
      )] = [
        (
          "corrupt-active-pointer",
          .invalidActiveLessonPointer,
          .carrierFailure("invalid_active_lesson_pointer")
        ),
        (
          "immutable-collision",
          .immutableLessonCollision("lesson.json"),
          .invalidBatch("immutable_lesson_collision")
        ),
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
        let configuration = try #require(configurations.first)
        try EvaluationWorkerFailureEvidence.publish(
          item.error,
          invocation: invocation,
          configuration: configuration
        )
        return EvaluationWorkerLaunchResult(termination: .rejected, processID: 41)
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
      await #expect(throws: item.expected) {
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

      // then — mutant: treating every workspace failure as carrier (or every nonzero exit as
      // invalid) changes the authenticated terminal result at the controller boundary.
      #expect(await launcher.failures.isEmpty)
    }
  }

  @Test func workerFailureEvidenceRejectsEveryIdentityAndClassificationMutation() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try makeEvaluationConfiguration(root: root).configuration
    let invocationID = UUID()
    let configurationSHA256 = String(repeating: "a", count: 64)
    let reason = EvaluationWorkspaceFailureReason.invalidActiveLessonPointer
    func evidence(
      schemaVersion: Int = PageEvaluationContract.schemaVersion,
      invocation: UUID? = nil,
      configurationDigest: String? = nil,
      attemptID: String? = nil,
      manifestDigest: String? = nil,
      classification: EvaluationPageTerminalClassification? = nil
    ) -> EvaluationWorkerFailureEvidence {
      EvaluationWorkerFailureEvidence(
        schemaVersion: schemaVersion,
        invocationID: invocation ?? invocationID,
        configurationSHA256: configurationDigest ?? configurationSHA256,
        attemptID: attemptID ?? configuration.attemptID,
        manifestSHA256: manifestDigest ?? configuration.approval.manifestSHA256,
        classification: classification ?? reason.classification,
        reason: reason
      )
    }
    let valid = evidence()
    let mutations = [
      evidence(schemaVersion: PageEvaluationContract.schemaVersion + 1),
      evidence(invocation: UUID()),
      evidence(configurationDigest: String(repeating: "b", count: 64)),
      evidence(attemptID: "different-attempt"),
      evidence(manifestDigest: String(repeating: "c", count: 64)),
      evidence(classification: .invalidBatch),
    ]

    // when
    try valid.validate(
      invocationID: invocationID,
      configurationSHA256: configurationSHA256,
      configuration: configuration
    )
    let mutationErrors = mutations.map { mutation in
      #expect(throws: EvaluationPagePipelineError.self) {
        try mutation.validate(
          invocationID: invocationID,
          configurationSHA256: configurationSHA256,
          configuration: configuration
        )
      }
    }

    // then
    #expect(mutationErrors.allSatisfy { $0 != nil })
  }

  @Test func workspaceFailureTaxonomyMapsEveryErrorToAClosedTerminalClass() {
    // given
    let digest = String(repeating: "a", count: 64)
    let otherDigest = String(repeating: "b", count: 64)
    let errorMappings: [(EvaluationWorkspaceError, EvaluationWorkspaceFailureReason)] = [
      (.sourceArtifactInsideWorkspace, .sourceArtifactInsideWorkspace),
      (.lessonArtifactInsideWorkspace, .lessonArtifactInsideWorkspace),
      (.sourceDigestMismatch(expected: digest, observed: otherDigest), .sourceDigestMismatch),
      (.invalidSourceArtifact, .invalidSourceArtifact),
      (.invalidSynthesisInput, .invalidSynthesisInput),
      (.missingLessonArtifact, .missingLessonArtifact),
      (.lessonDigestMismatch(expected: digest, observed: otherDigest), .lessonDigestMismatch),
      (.invalidLessonArtifact, .invalidLessonArtifact),
      (.invalidActiveLessonPointer, .invalidActiveLessonPointer),
      (
        .activeLessonDigestMismatch(expected: digest, observed: otherDigest),
        .activeLessonDigestMismatch
      ),
      (.activeLessonIdentityMismatch, .activeLessonIdentityMismatch),
      (.immutableLessonCollision("lesson.json"), .immutableLessonCollision),
      (.inputDigestMismatch(expected: digest, observed: otherDigest), .inputDigestMismatch),
      (.inputIsNotUTF8, .inputIsNotUTF8),
      (
        .inputGraphemeLimitExceeded(PageEvaluationContract.maximumInputGraphemes + 1),
        .inputGraphemeLimitExceeded
      ),
      (.unexpectedWorkspaceContents(["unexpected"]), .unexpectedWorkspaceContents),
    ]
    let carrierReasons: Set<EvaluationWorkspaceFailureReason> = [
      .lessonDigestMismatch,
      .invalidActiveLessonPointer,
      .activeLessonDigestMismatch,
      .activeLessonIdentityMismatch,
      .inputDigestMismatch,
      .policyMismatch,
    ]

    // when
    let mappedReasons = errorMappings.map { $0.0.failureReason }
    let mappedClassifications = Dictionary(
      uniqueKeysWithValues: EvaluationWorkspaceFailureReason.allCases.map { reason in
        (reason, reason.classification)
      }
    )

    // then — each closed workspace error retains its exact durable reason, and every reason's
    // carrier/invalid boundary is exhaustive rather than inferred from two representatives.
    #expect(mappedReasons == errorMappings.map(\.1))
    #expect(Set(mappedClassifications.keys) == Set(EvaluationWorkspaceFailureReason.allCases))
    for reason in EvaluationWorkspaceFailureReason.allCases {
      #expect(
        mappedClassifications[reason]
          == (carrierReasons.contains(reason) ? .carrierFailure : .invalidBatch)
      )
    }
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

  @Test func rejectedLessonSynthesisPublishesOneClosedRejectionReport() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = try makeEvaluationConfiguration(root: root, attemptID: "synthesis-base")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [base.configuration])
    let paths = EvaluationController.PagePipelinePaths(
      evaluationRoot: base.configuration.evaluationRootURL
    )
    let synthesisInput = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "selected_target_classes": ["noise.volatile_value"],
      "schema_version": 1,
    ])
    let synthesisPrompt = Data("Produce one bounded lesson set.".utf8)
    let synthesisPromptURL = root.appendingPathComponent("artifacts/synthesis.md")
    try synthesisPrompt.write(to: synthesisPromptURL)
    var categories = frozen.context.manifest.categories
    let synthesisPromptRecord = EvaluationManifestArtifact(
      role: "synthesis",
      path: "artifacts/synthesis.md",
      bytes: synthesisPrompt.count,
      sha256: SHA256Digest.hex(synthesisPrompt)
    )
    categories["prompts"] = EvaluationManifestCategory(
      artifacts: (categories["prompts"]?.artifacts ?? []) + [synthesisPromptRecord],
      sha256: categories["prompts"]?.sha256 ?? String(repeating: "a", count: 64)
    )
    categories["feedback"] = EvaluationManifestCategory(
      artifacts: [],
      sha256: String(repeating: "e", count: 64)
    )
    let manifest = EvaluationFreezeManifest(
      schemaVersion: frozen.context.manifest.schemaVersion,
      decision: frozen.context.manifest.decision,
      experiment: frozen.context.manifest.experiment,
      protocolBinding: frozen.context.manifest.protocolBinding,
      categories: categories,
      protectedArtifacts: frozen.context.manifest.protectedArtifacts + [
        EvaluationManifestProtectedArtifact(
          path: synthesisPromptRecord.path,
          bytes: synthesisPromptRecord.bytes,
          sha256: synthesisPromptRecord.sha256
        )
      ]
    )
    let context = EvaluationFreezeContext(
      repositoryRoot: frozen.context.repositoryRoot,
      manifest: manifest,
      receipt: frozen.context.receipt,
      runtime: frozen.context.runtime,
      runOrderJSON: frozen.context.runOrderJSON
    )
    let clean = try EvaluationPageLessonBinding.clean()
    let configuration = EvaluationAttemptConfiguration(
      attemptID: "page-synthesis-test",
      fixtureID: "pc-synthesis-01",
      taskID: "page-000000000001",
      split: "development",
      stage: "synthesis",
      frozenOrderIndex: 0,
      frozenOrderKey: String(repeating: "d", count: 64),
      replicate: 1,
      condition: .synthesis,
      evaluationRoot: base.configuration.evaluationRoot,
      sourceArtifactPath: paths.synthesisInput.path,
      sourceSHA256: SHA256Digest.hex(synthesisInput),
      inputSHA256: SHA256Digest.hex(synthesisInput),
      lessonSource: .clean,
      taskPromptPath: synthesisPromptURL.path,
      taskPromptSHA256: synthesisPromptRecord.sha256,
      resultPath: paths.results.appendingPathComponent("page-synthesis-test.json").path,
      fixedTimestamp: base.configuration.fixedTimestamp,
      protocolSHA256: base.configuration.protocolSHA256,
      lessonSetDigest: clean.digest,
      expectedPolicyVersion: base.configuration.expectedPolicyVersion,
      approval: base.configuration.approval,
      provenance: base.configuration.provenance
    )
    let result = makeEvaluationResult(
      configuration: configuration,
      replacementDisposition: .ineligible
    )
    let lint = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "accepted": false,
      "errors": [["code": "lesson.too_specific"]],
      "schema_version": 1,
    ])
    let launcher = ScriptedEvaluationWorkerLauncher { _, _, _ in
      EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
    let experiment = EvaluationPageExperiment(
      freezeVerifier: StaticEvaluationFreezeVerifier(context: context),
      artifacts: StaticEvaluationProtectedArtifactRunner(output: lint),
      launcher: launcher
    )
    try experiment.prepare(paths)
    try EvaluationDurablePublication.publish(synthesisInput, to: paths.synthesisInput)
    try EvaluationDurablePublication.publish(
      Data(#"{"schema_version":1}"#.utf8),
      to: paths.synthesisCandidate
    )
    let execution = EvaluationSynthesisExecution(
      result: result,
      attempts: [
        [
          "attempt_id": result.attemptID,
          "attempt_index": 1,
          "conversation_id": result.conversationID,
          "process_uuid": result.processUUID.uuidString.lowercased(),
          "raw_output": result.rawOutput ?? NSNull(),
          "runtime_outcome": "completed",
        ]
      ]
    )

    // when
    let outcome = try await experiment.promote(
      synthesis: execution,
      freeze: context,
      paths: paths
    )

    // then — no rewrite or second synthesis is possible; all rejection provenance is immutable.
    #expect(outcome == .rejected)
    #expect(FileManager.default.fileExists(atPath: paths.promotedTemporary.path) == false)
    #expect(FileManager.default.fileExists(atPath: paths.promotionReceipt.path) == false)
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: paths.synthesisRejectionReport))
        as? [String: Any]
    )
    #expect(report["outcome"] as? String == "page_task_specific_failure")
    #expect(report["rejection_codes"] as? [String] == ["lesson.too_specific"])
    #expect(
      report["synthesis_transcript_sha256"] as? String
        == SHA256Digest.hex(try Data(contentsOf: paths.synthesisTranscript))
    )
    #expect(await launcher.observations.isEmpty)
  }

  @Test func synthesisInputInvocationCarriesTheManifestBoundFeedbackGeneratorDigest() async throws {
    // given — synthesis.py requires the digest as an explicit provenance input; the feedback
    // category is the approved source rather than a caller-supplied duplicate.
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = try makeEvaluationConfiguration(root: root, attemptID: "synthesis-input-contract")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [base.configuration])
    let relativeInputs = [
      "\(EvaluationController.pageRootPath)/contracts/error-codes.json",
      "\(EvaluationController.pageRootPath)/contracts/feedback-templates.json",
      "\(EvaluationController.pageRootPath)/schemas/lesson-set.schema.json",
      "\(EvaluationController.pageRootPath)/contracts/lesson-lint-rules.json",
    ]
    let protectedInputs = try relativeInputs.map { relative in
      let url = root.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = Data(#"{"schema_version":1}"#.utf8)
      try data.write(to: url)
      return EvaluationManifestProtectedArtifact(
        path: relative,
        bytes: data.count,
        sha256: SHA256Digest.hex(data)
      )
    }
    let feedbackGeneratorSHA256 = String(repeating: "e", count: 64)
    var categories = frozen.context.manifest.categories
    categories["feedback"] = EvaluationManifestCategory(
      artifacts: [],
      sha256: feedbackGeneratorSHA256
    )
    let context = EvaluationFreezeContext(
      repositoryRoot: frozen.context.repositoryRoot,
      manifest: EvaluationFreezeManifest(
        schemaVersion: frozen.context.manifest.schemaVersion,
        decision: frozen.context.manifest.decision,
        experiment: frozen.context.manifest.experiment,
        protocolBinding: frozen.context.manifest.protocolBinding,
        categories: categories,
        protectedArtifacts: frozen.context.manifest.protectedArtifacts + protectedInputs
      ),
      receipt: frozen.context.receipt,
      runtime: frozen.context.runtime,
      runOrderJSON: frozen.context.runOrderJSON
    )
    let output = try EvaluationCanonicalJSON.data(fromJSONObject: ["schema_version": 1])
    let runner = ScriptedEvaluationProtectedArtifactRunner(output: output)
    let launcher = ScriptedEvaluationWorkerLauncher { _, _, _ in
      EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
    let experiment = EvaluationPageExperiment(
      freezeVerifier: StaticEvaluationFreezeVerifier(context: context),
      artifacts: runner,
      launcher: launcher
    )
    let paths = EvaluationController.PagePipelinePaths(
      evaluationRoot: base.configuration.evaluationRootURL
    )
    try experiment.prepare(paths)

    // when
    try await experiment.buildSynthesisInput(freeze: context, paths: paths)

    // then — mutant: omitting the required flag (or sourcing another digest) cannot launch the
    // production CLI contract while this assertion still passes.
    let invocations = await runner.invocations
    #expect(invocations.count == 1)
    let invocation = try #require(invocations.first)
    let flagIndex = try #require(
      invocation.arguments.firstIndex(of: "--feedback-generator-sha256")
    )
    #expect(invocation.arguments.index(after: flagIndex) < invocation.arguments.endIndex)
    #expect(invocation.arguments[flagIndex + 1] == feedbackGeneratorSHA256)
    #expect(await launcher.observations.isEmpty)
  }

  @Test func pageRecordPreservesNullableFailedToolSafetyAndUsesAnAbsoluteManifestPath()
    async throws
  {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "record-safety")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let result = makeEvaluationResult(
      configuration: configured.configuration,
      replacementDisposition: .ineligible,
      tools: [
        EvaluationToolRecord(
          name: "web_fetch",
          path: nil,
          status: EvaluationToolContract.failedStatus
        ),
        EvaluationToolRecord(
          name: EvaluationToolContract.requiredToolName,
          path: nil,
          status: EvaluationToolContract.failedStatus
        ),
      ]
    )
    let sourceRelativePath = try #require(
      frozen.context.manifest.protectedArtifacts.first {
        $0.sha256 == configured.configuration.sourceSHA256
      }?.path
    )
    let fixture = EvaluationPageFixture(
      fixtureID: configured.configuration.fixtureID,
      split: configured.configuration.split,
      sourceRelativePath: sourceRelativePath,
      goldRelativePath: sourceRelativePath,
      taskID: configured.configuration.taskID,
      sourceSHA256: configured.configuration.sourceSHA256
    )
    let slot = EvaluationPageTaskSlot(
      stage: configured.configuration.stage,
      split: configured.configuration.split,
      orderIndex: configured.configuration.frozenOrderIndex,
      blockIndex: 0,
      orderKey: configured.configuration.frozenOrderKey,
      blockOrderKey: String(repeating: "b", count: 64),
      fixtureID: configured.configuration.fixtureID,
      replicate: configured.configuration.replicate,
      condition: configured.configuration.condition.runOrderValue,
      lessonSource: configured.configuration.lessonSource,
      workerProcessKey: String(repeating: "e", count: 64)
    )
    let recordData = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "attempt_id": result.attemptID,
      "carrier_receipt_sha256": result.carrierReceiptSHA256,
    ])
    let runner = ScriptedEvaluationProtectedArtifactRunner(output: recordData)

    // when
    _ = try await EvaluationPageRecordBuilder(artifacts: runner).writeBundle(
      attempts: [
        EvaluationRecordedAttempt(
          result: result,
          resultOrEnvelopeSHA256: String(repeating: "f", count: 64)
        )
      ],
      runOrder: EvaluationPageRunOrder(
        canaryProcesses: [],
        taskSlots: [slot],
        synthesis: EvaluationPageSynthesisSlot(
          orderKey: SHA256Digest.hex("unused-synthesis"),
          workerProcessKey: SHA256Digest.hex("unused-synthesis-worker"),
          promptPath: "unused"
        )
      ),
      catalog: EvaluationPageFixtureCatalog(
        fixtures: [fixture],
        byID: [fixture.fixtureID: fixture]
      ),
      freeze: frozen.context,
      lifecycleReceiptSHA256: "",
      outputURL: root.appendingPathComponent("records.json")
    )

    // then — rejecting a missing path on either a failed required read or an unknown tool erases
    // scorer-owned safety; a relative manifest argument makes page-record depend on the CWD.
    let invocation = try #require(await runner.invocations.first)
    let attemptFlag = try #require(invocation.arguments.firstIndex(of: "--attempt"))
    let attemptData = try EvaluationPathSecurity.readRegularSingleLinkFile(
      at: URL(fileURLWithPath: invocation.arguments[attemptFlag + 1])
    )
    let attemptObject = try #require(
      JSONSerialization.jsonObject(with: attemptData) as? [String: Any]
    )
    let toolEvents = try #require(attemptObject["tool_events"] as? [[String: Any]])
    #expect(toolEvents.count == 2)
    #expect(toolEvents[0]["name"] as? String == "web_fetch")
    #expect(toolEvents[0]["path"] is NSNull)
    #expect(toolEvents[1]["name"] as? String == EvaluationToolContract.requiredToolName)
    #expect(toolEvents[1]["path"] is NSNull)
    let manifestFlag = try #require(invocation.arguments.firstIndex(of: "--manifest"))
    #expect(
      invocation.arguments[manifestFlag + 1]
        == root.appendingPathComponent("config/manifest.json").standardizedFileURL.path
    )
    #expect(invocation.arguments[manifestFlag + 1].hasPrefix("/"))
  }

  @Test func prelaunchJournalDebitsUnknownSendsAndRefusesSameManifestContinuation() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = String(repeating: "a", count: 64)
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: root,
      manifestSHA256: manifest,
      freezeCommit: String(repeating: "b", count: 40),
      fixedTimestamp: "2026-08-26T00:00:00Z",
      journalName: "page-\(manifest).jsonl"
    )

    // when — reservation is durable before a worker could make either send.
    let reservation = try journal.reserve(
      invocationID: UUID(),
      invocationCoreSHA256: String(repeating: "c", count: 64),
      attemptIDs: ["attempt-1"],
      maximumResponsesSends: 2
    )

    // then
    #expect(reservation.reservedResponsesSends == 2)
    #expect(
      reservation.reservedAccountedTokens
        == 2 * PageEvaluationContract.missingUsageTokenProxy
    )
    let bytes = try Data(contentsOf: journal.url)
    #expect(String(decoding: bytes, as: UTF8.self).contains(#""kind":"launch_reserved""#))
    #expect(throws: EvaluationControllerJournalError.sameManifestContinuationRefused) {
      _ = try EvaluationControllerJournal.startNew(
        evaluationRoot: root,
        manifestSHA256: manifest,
        freezeCommit: String(repeating: "b", count: 40),
        fixedTimestamp: "2026-08-26T00:00:00Z",
        journalName: "page-\(manifest).jsonl"
      )
    }
    #expect(try Data(contentsOf: journal.url) == bytes)

    // A path substitution after creation cannot redirect a later append into another file.
    let external = root.appendingPathComponent("external-ledger.jsonl")
    let externalData = Data("must-not-change".utf8)
    try externalData.write(to: external)
    try FileManager.default.removeItem(at: journal.url)
    try FileManager.default.linkItem(at: external, to: journal.url)
    #expect(throws: EvaluationPathSecurityError.insecureFile(journal.url.lastPathComponent)) {
      _ = try journal.reserve(
        invocationID: UUID(),
        invocationCoreSHA256: String(repeating: "d", count: 64),
        attemptIDs: ["attempt-2"],
        maximumResponsesSends: 2
      )
    }
    #expect(try Data(contentsOf: external) == externalData)
  }

  @Test func workerAuthorizationMustMatchTheDurableControllerReservation() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = String(repeating: "a", count: 64)
    let commit = String(repeating: "b", count: 40)
    let timestamp = "2026-08-26T00:00:00Z"
    let invocationID = UUID()
    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: root,
      manifestSHA256: manifest,
      freezeCommit: commit,
      fixedTimestamp: timestamp,
      journalName: "page-\(manifest).jsonl"
    )
    let reservation = try journal.reserve(
      invocationID: invocationID,
      invocationCoreSHA256: String(repeating: "c", count: 64),
      attemptIDs: ["attempt-1"],
      maximumResponsesSends: 2
    )
    let authorization = EvaluationWorkerAuthorization(
      journalPath: journal.url.path,
      reservation: reservation,
      reservationSHA256: SHA256Digest.hex(
        try EvaluationCanonicalJSON.data(encoding: reservation)
      )
    )

    // when
    try EvaluationControllerJournal.authorize(
      authorization,
      invocationID: invocationID,
      invocationCoreSHA256: String(repeating: "c", count: 64),
      attemptIDs: ["attempt-1"],
      manifestSHA256: manifest,
      freezeCommit: commit,
      fixedTimestamp: timestamp,
      evaluationRoot: root
    )
    try journal.recordLaunch(
      kind: .launchCompleted,
      invocationID: invocationID,
      attemptIDs: ["attempt-1"],
      observedResponsesSends: 2,
      observedAccountedTokens: 1,
      processID: 42
    )
    let replayError = #expect(throws: EvaluationControllerJournalError.authorizationMismatch) {
      try EvaluationControllerJournal.authorize(
        authorization,
        invocationID: invocationID,
        invocationCoreSHA256: String(repeating: "c", count: 64),
        attemptIDs: ["attempt-1"],
        manifestSHA256: manifest,
        freezeCommit: commit,
        fixedTimestamp: timestamp,
        evaluationRoot: root
      )
    }
    let coreError = #expect(throws: EvaluationWorkerInvocationError.invalidAuthorization) {
      try authorization.validate(
        invocationID: invocationID,
        invocationCoreSHA256: String(repeating: "d", count: 64)
      )
    }
    let attemptError = #expect(throws: EvaluationControllerJournalError.authorizationMismatch) {
      try EvaluationControllerJournal.authorize(
        authorization,
        invocationID: invocationID,
        invocationCoreSHA256: String(repeating: "c", count: 64),
        attemptIDs: ["forged-attempt"],
        manifestSHA256: manifest,
        freezeCommit: commit,
        fixedTimestamp: timestamp,
        evaluationRoot: root
      )
    }

    // then — a terminal reservation cannot be replayed or rebound to another core/attempt.
    #expect(replayError != nil)
    #expect(coreError != nil)
    #expect(attemptError != nil)
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

  @Test func toolDeviationTakesPrecedenceOverACompetingCarrierDigestMismatch() async throws {
    // given — the model proposes a forbidden path while the recorded second request also carries
    // the wrong fenced payload. The model-visible task deviation must not become a harness defect.
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let provider = SequenceProvider(scriptedTwoRoundResponses(requestedPath: "other.json"))
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let head = HTTPStreamHead(statusCode: 200, headers: [:])
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([.stream(head, []), .stream(head, [])])
    )
    let wrongCarrier = LabeledContext(
      label: "file_read",
      content: #"{"schema_version":1,"wrong":true}"#,
      nonce: String(repeating: "a", count: 32)
    ).render()
    func request(input: String) throws -> HTTPRequest {
      HTTPRequest(
        method: .post,
        url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
        headers: [:],
        body: try JSONSerialization.data(withJSONObject: [
          "input": input,
          "model": PageEvaluationContract.wireModel,
        ]),
        timeout: .seconds(1),
        responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
      )
    }
    _ = try await recorder.openStream(request(input: "read the approved input"))
    _ = try await recorder.openStream(request(input: wrongCarrier))

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
      )
    )

    // then — mutant: digest-first classification would return harnessFailure and hide the tool
    // safety signal from the scorer.
    #expect(result.outcome == .toolContractFailure)
    #expect(result.criticalCode == "unexpected_file_read_path")
    #expect(result.replacementDisposition == .ineligible)
  }

  @Test func observedToolDeviationCannotBecomeReplacementEligibleAfterAProviderFailure()
    async throws
  {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let firstRound = try #require(
      scriptedTwoRoundResponses(requestedPath: "other.json").first
    )
    let provider = SequenceProvider(
      [firstRound],
      then: ProviderError.partialStreamWithoutCompletedTerminal
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
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([.stream(HTTPStreamHead(statusCode: 200, headers: [:]), [])])
    )
    let firstRequest = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: [
        "input": "read the approved input",
        "model": PageEvaluationContract.wireModel,
      ]),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
    )
    _ = try await recorder.openStream(firstRequest)

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
      )
    )

    // then — deferring an observed wrong-path tool until a second send lets the competing
    // transport failure spend the one whole-attempt replacement.
    #expect(result.outcome == .toolContractFailure)
    #expect(result.criticalCode == EvaluationToolViolation.unexpectedFileReadPath.rawValue)
    #expect(result.replacementDisposition == .ineligible)
  }

  @Test func firstSendAdmissionStopRemainsAnIncompleteControllerBudgetOutcome() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let provider = FailingStreamingProvider(
      cause: .terminal(status: nil, message: "must not reach provider")
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

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))
    ).run(
      configuration: configured.configuration,
      sendBudget: EvaluationSendBudgetSnapshot(
        stageAccountedTokens: PageEvaluationContract.pageLimits.accountedTokenThreshold,
        globalAccountedTokens: 0,
        stageResponsesSends: 0,
        globalResponsesSends: 0,
        stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
        stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
      )
    )

    // then — mutant: the former default branch converted a valid controller admission cap into a
    // harness integrity failure, invalidating the batch instead of leaving it incomplete.
    #expect(await provider.streamCalls == 0)
    #expect(result.outcome == .budgetStopped)
    #expect(result.criticalCode == nil)
    #expect(result.replacementReason == EvaluationSendBudgetSnapshot.stageAccountedTokenCap)
    #expect(EvaluationController.isIncompleteFailure(result))
  }

  @Test func liveIntegrityMutationBetweenRoundsStopsBeforeTheSecondProviderSend() async throws {
    // given — the first response requests the sole file read; the live binding then changes.
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let budget = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
      stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
    )
    let progressFixture = try startEvaluationAttemptProgress(
      configuration: configured.configuration,
      configurationURL: configured.configurationURL,
      freezeInputs: frozen.inputs,
      budget: budget,
      journalName: "live-integrity-progress.jsonl"
    )
    let provider = SequenceProvider(scriptedTwoRoundResponses())
    let admission = SequencedIntegrityAdmission()
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([
        .stream(HTTPStreamHead(statusCode: 200, headers: [:]), [])
      ]),
      progressRecorder: progressFixture.recorder,
      attemptID: configured.configuration.attemptID
    )
    let request = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: [
        "input": "read the approved input",
        "model": PageEvaluationContract.wireModel,
      ]),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
    )
    _ = try await recorder.openStream(request)

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder,
      progressRecorder: progressFixture.recorder
    ).run(
      configuration: configured.configuration,
      sendBudget: budget,
      integrityAdmission: { await admission.next() }
    )
    let progress = try #require(
      try EvaluationAttemptProgressRecorder.loadIfPresent(
        invocationID: progressFixture.invocation.invocationID,
        invocationConfigurationSHA256: progressFixture.invocation.configurationSHA256,
        configurations: [configured.configuration]
      )
    )

    // then — checking only once at worker startup would make provider call 2 happen; deleting the
    // runner's durable usage or tool forwarding loses the completed first-round evidence.
    #expect(await provider.requests.count == 1)
    #expect(result.outcome == .harnessFailure)
    #expect(result.criticalCode == "evaluation-freeze-integrity")
    #expect(result.audit.isEmpty == false)
    #expect(progress.attempts.first?.responsesRequests == result.http.responsesSends)
    #expect(progress.attempts.first?.responsesSends == 1)
    #expect(progress.attempts.first?.provenNotStartedResponsesSends == 0)
    #expect(progress.attempts.first?.usage == result.usage)
    #expect(progress.attempts.first?.usage.count == 1)
    #expect(progress.attempts.first?.fileReads == 1)
    #expect(progress.attempts.first?.accountedTokens == 0)
    let persisted = try JSONDecoder().decode(
      EvaluationAttemptResult.self,
      from: EvaluationCanonicalJSON.data(encoding: result)
    )
    #expect(persisted.audit == result.audit)
  }

  @Test func preInferenceNoStartSendCountsTowardTheCapWithoutAProxyDebit() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "no-start-accounting")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let budget = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
      stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
    )
    let progressFixture = try startEvaluationAttemptProgress(
      configuration: configured.configuration,
      configurationURL: configured.configurationURL,
      freezeInputs: frozen.inputs,
      budget: budget,
      journalName: "no-start-accounting.jsonl"
    )
    let provider = FailingStreamingProvider(
      cause: .terminal(status: 401, message: "clean pre-inference rejection"),
      accounting: .notStarted
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
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([
        .stream(HTTPStreamHead(statusCode: 401, headers: [:]), [])
      ]),
      progressRecorder: progressFixture.recorder,
      attemptID: configured.configuration.attemptID
    )
    let request = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: [
        "input": "read the approved input",
        "model": PageEvaluationContract.wireModel,
      ]),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
    )
    _ = try await recorder.openStream(request)

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder,
      progressRecorder: progressFixture.recorder
    ).run(
      configuration: configured.configuration,
      sendBudget: budget
    )
    let noStartProgress = try #require(
      try EvaluationAttemptProgressRecorder.loadIfPresent(
        invocationID: progressFixture.invocation.invocationID,
        invocationConfigurationSHA256: progressFixture.invocation.configurationSHA256,
        configurations: [configured.configuration]
      )
    )

    // then — a typed no-start rejection consumes the send cap but never the missing-usage proxy.
    #expect(await provider.streamCalls == 1)
    #expect(result.http.responsesSends.count == 1)
    #expect(result.http.provenNotStartedResponsesSends == 1)
    #expect(result.usage.isEmpty)
    #expect(result.accountedTokens == 0)
    #expect(noStartProgress.attempts.first?.responsesSends == 1)
    #expect(noStartProgress.attempts.first?.responsesRequests == result.http.responsesSends)
    #expect(noStartProgress.attempts.first?.provenNotStartedResponsesSends == 1)
    #expect(noStartProgress.attempts.first?.usage.isEmpty == true)
    #expect(noStartProgress.attempts.first?.accountedTokens == 0)
  }

  @Test func deadlineAfterToolResponseDoesNotDuplicateTheProviderCallUsage() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "deadline-dedupe")
    let firstResponse = try #require(
      scriptedTwoRoundResponses(
        firstUsage: ChatUsage(promptTokens: 11, completionTokens: 13, totalTokens: 24)
      ).first
    )
    let provider = SequenceProvider([firstResponse])
    let roster = ProviderRoster(
      primary: LLMRouteBinding(
        provider: provider,
        wireModel: PageEvaluationContract.wireModel,
        configuredReference: PageEvaluationContract.providerReference,
        costPolicy: .includedPlan,
        reservationPolicy: .chatGPTReplayState
      )
    )
    let recorder = EvaluationHTTPRecorder(
      base: ScriptedHTTPExecutor([
        .stream(HTTPStreamHead(statusCode: 200, headers: [:]), [])
      ])
    )
    let request = HTTPRequest(
      method: .post,
      url: LLMProviderDescriptor.chatGPTResponsesEndpoint,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: [
        "input": "read the approved input",
        "model": PageEvaluationContract.wireModel,
      ]),
      timeout: .seconds(1),
      responseBodyPolicy: .streaming(maximumUnreadBytes: 1_024, errorBytes: 1_024)
    )
    _ = try await recorder.openStream(request)
    let clock = ContinuousClock()
    let start = clock.now
    let nowCalls = Mutex(0)

    // when
    let result = try await EvaluationAttemptRunner(
      roster: roster,
      httpRecorder: recorder,
      providerCallIDGenerator: SequentialCallIDGenerator(),
      runtimeNow: {
        nowCalls.withLock { calls in
          calls += 1
          return calls >= 5 ? start.advanced(by: .seconds(181)) : start
        }
      }
    ).run(
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

    // then — the deadline degradation reuses call-1 and must not append its conservative row twice.
    #expect(await provider.requests.count == 1)
    #expect(result.replacementReason == "deadline")
    #expect(result.http.responsesSends.count == 1)
    #expect(result.usage.count == 1)
    #expect(result.usage.first?.providerCallID == "call-1")
    #expect(result.usage.first?.totalTokens == 24)
    #expect(result.accountedTokens == 24)
  }

  @Test func credentialAndTerminalFreeCausesKeepTheirTypedReplacementClassification() async throws {
    // given — every failure has no scorable output. The typed cause, not a diagnostic string or the
    // broad providerUnavailable degradation, must distinguish frozen replacement eligibility.
    #expect(PageEvaluationContract.runBudget.retryBudget == 1)
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let budget = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: PageEvaluationContract.pageLimits.accountedTokenThreshold,
      stageResponsesSendCap: PageEvaluationContract.pageLimits.maximumResponsesSends
    )

    func run(_ cause: ProviderError) async throws -> EvaluationAttemptResult {
      let provider = FailingStreamingProvider(cause: cause)
      let roster = ProviderRoster(
        primary: LLMRouteBinding(
          provider: provider,
          wireModel: PageEvaluationContract.wireModel,
          configuredReference: PageEvaluationContract.providerReference,
          costPolicy: .includedPlan,
          reservationPolicy: .chatGPTReplayState
        )
      )
      let result = try await EvaluationAttemptRunner(
        roster: roster,
        httpRecorder: EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([]))
      ).run(configuration: configured.configuration, sendBudget: budget)
      #expect(await provider.streamCalls == 1)
      return result
    }

    // when
    let terminalFree = try await run(.partialStreamWithoutCompletedTerminal)
    let refreshCompleted = try await run(.credentialRefreshCompleted)
    let refreshExhausted = try await run(.credentialRefreshExhausted)
    let credentialStateUnavailable = try await run(.credentialStateUnavailable)
    let genericTerminal = try await run(.terminal(status: nil, message: "ended"))

    // then — only the exact frozen temporary causes are eligible. A successful durable refresh is
    // still an incomplete original attempt, but it cannot spend a replacement; neither can a marker
    // persistence failure that would let a new worker reload the rejected credential.
    #expect(terminalFree.outcome == .providerFailure)
    #expect(terminalFree.rawOutput == nil)
    #expect(terminalFree.replacementDisposition == .eligible)
    #expect(terminalFree.replacementReason == "partial_stream_without_completed_terminal")
    #expect(refreshCompleted.outcome == .providerFailure)
    #expect(refreshCompleted.rawOutput == nil)
    #expect(refreshCompleted.replacementDisposition == .ineligible)
    #expect(refreshCompleted.replacementReason == "credential_refresh_completed")
    #expect(refreshExhausted.replacementDisposition == .eligible)
    #expect(refreshExhausted.replacementReason == "credential_refresh_exhausted")
    #expect(credentialStateUnavailable.replacementDisposition == .ineligible)
    #expect(credentialStateUnavailable.replacementReason == "credential_state_unavailable")
    #expect(genericTerminal.replacementDisposition == .ineligible)
    #expect(genericTerminal.replacementReason == "provider_terminal")
  }

  @Test func freezeManifestRejectsBudgetContractDrift() throws {
    // given — the manifest binds the shared contract; the controller only projects that contract
    // into its stage-specific shape instead of owning another set of literals.
    let validCategory = EvaluationManifestCategory(
      artifacts: [],
      values: PageEvaluationContract.budgetManifestValues,
      sha256: String(repeating: "a", count: 64)
    )
    let valid = EvaluationFreezeManifest(
      categories: ["budget": validCategory],
      protectedArtifacts: []
    )
    var driftedValues = try #require(PageEvaluationContract.budgetManifestValues.objectValue)
    driftedValues["page_attempt_cap"] = .integer(77)
    let drifted = EvaluationFreezeManifest(
      categories: [
        "budget": EvaluationManifestCategory(
          artifacts: [],
          values: .object(driftedValues),
          sha256: validCategory.sha256
        )
      ],
      protectedArtifacts: []
    )

    // when
    try valid.validateBudgetContract()
    let driftError = #expect(throws: EvaluationFreezeError.budgetContractMismatch) {
      try drifted.validateBudgetContract()
    }

    // then — a decoder that drops budget values would accept the drifted manifest.
    #expect(driftError != nil)
  }

}

private actor RefusingIfCalledFreezeVerifier: EvaluationFreezeVerifying {
  private(set) var calls = 0

  func verify(_ inputs: EvaluationFreezeInputs) async throws -> EvaluationFreezeContext {
    calls += 1
    throw EvaluationHarnessTestError.unexpectedFreezeCall
  }
}

private enum EvaluationHarnessTestError: Error {
  case unexpectedFreezeCall
  case unexpectedCanaryInvocation
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

private actor LifecycleEvents {
  private var stored: [String] = []

  var values: [String] { stored }

  func append(_ value: String) {
    stored.append(value)
  }
}

private struct RecordingLifecycleResource: EvaluationWorkerResource {
  let events: LifecycleEvents

  func shutdownCredentials() async throws {
    await events.append("credentials_closed")
  }

  func shutdownTransport() async throws {
    await events.append("transport_closed")
  }
}

private enum LifecycleTestError: Error {
  case operation
  case credentials
}

private struct FailingLifecycleResource: EvaluationWorkerResource {
  let events: LifecycleEvents

  func shutdownCredentials() async throws {
    await events.append("credentials_failed")
    throw LifecycleTestError.credentials
  }

  func shutdownTransport() async throws {
    await events.append("transport_closed")
  }
}

private func scriptedTwoRoundResponses(
  requestedPath: String = PageEvaluationContract.inputFileName,
  firstUsage: ChatUsage? = .zero
) -> [ChatResponse] {
  [
    ChatResponse(
      content: "",
      finishReason: "tool_calls",
      usage: firstUsage,
      costFromProvider: nil,
      toolCalls: [
        ToolCall(
          id: "read-input",
          name: EvaluationToolContract.requiredToolName,
          argumentsJSON: #"{"path":"\#(requestedPath)"}"#
        )
      ],
      reportedModel: PageEvaluationContract.wireModel
    ),
    ChatResponse(
      content: #"{"schema_version":1}"#,
      finishReason: "stop",
      usage: .zero,
      costFromProvider: nil,
      reportedModel: PageEvaluationContract.wireModel
    ),
  ]
}

private actor SequencedIntegrityAdmission {
  private var calls = 0

  func next() -> ProviderRoundTripAdmission {
    calls += 1
    return calls == 1 ? .allow : .deny(cap: "evaluation-freeze-integrity")
  }
}

private actor FailingStreamingProvider: LLMProvider {
  let cause: ProviderError
  let accounting: ProviderFailureAccounting
  private(set) var streamCalls = 0

  init(
    cause: ProviderError,
    accounting: ProviderFailureAccounting = .mayHaveStarted(observing: 1)
  ) {
    self.cause = cause
    self.accounting = accounting
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    Issue.record("evaluation streaming must not fall back to a buffered provider call")
    throw cause
  }

  nonisolated func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make { _ in
      await self.recordStreamCall()
      return .failed(
        ProviderFailure(
          cause: self.cause,
          accounting: self.accounting
        )
      )
    }
  }

  private func recordStreamCall() {
    streamCalls += 1
  }
}
