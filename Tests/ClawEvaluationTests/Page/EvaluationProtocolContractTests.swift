import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationProtocolContractTests {
  @Test func pageExperimentDebitsRecoverySeedBeforeTheFirstCanaryWorker() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeCanaryControllerFixture(root: root)
    let repository = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    let pageRoot = EvaluationController.pageRootPath
    let approvedManifest = try EvaluationJSONFile.decode(
      EvaluationFreezeManifest.self,
      from: repository.appendingPathComponent("\(pageRoot)/freeze/page-manifest.json")
    )
    let manifest = EvaluationFreezeManifest(
      schemaVersion: approvedManifest.schemaVersion,
      decision: approvedManifest.decision,
      experiment: approvedManifest.experiment,
      protocolBinding: approvedManifest.protocolBinding,
      categories: approvedManifest.categories,
      protectedArtifacts: approvedManifest.protectedArtifacts.filter {
        $0.path.hasPrefix("\(pageRoot)/")
      }
    )
    try manifest.validateBudgetContract(for: .pageChange)
    let canarySource = try #require(
      manifest.artifact(role: "canary_base_task", category: "configuration")
    )
    let canaryContract = try #require(
      manifest.artifact(role: "canary", category: "configuration")
    )
    let cleanLessons = try #require(
      manifest.artifact(role: "canary_clean_lessons", category: "configuration")
    )
    let nonemptyLessons = try #require(
      manifest.artifact(role: "canary_nonempty_lessons", category: "configuration")
    )
    let canarySourceObject = try #require(
      JSONSerialization.jsonObject(
        with: try EvaluationManifestBoundArtifactReader.read(
          canarySource,
          repositoryRoot: repository
        ).data
      ) as? [String: Any]
    )
    let canaryFixtureID = try #require(canarySourceObject["fixture_id"] as? String)
    let canaryTaskID = try #require(canarySourceObject["task_id"] as? String)
    let canaryProcesses = fixture.order.canaryProcesses.map { process in
      EvaluationPageCanaryProcessSlot(
        process: process.process,
        workerProcessKey: process.workerProcessKey,
        attempts: process.attempts.map { attempt in
          let lessonPath: String? =
            switch attempt.lessonSource {
            case .clean: cleanLessons.path
            case .artifact: nonemptyLessons.path
            case .durableActive: nil
            }
          return EvaluationPageCanaryAttemptSlot(
            attemptIndex: attempt.attemptIndex,
            fixtureID: canaryFixtureID,
            taskID: canaryTaskID,
            process: attempt.process,
            workerProcessKey: attempt.workerProcessKey,
            condition: attempt.condition,
            lessonSource: attempt.lessonSource,
            lessonArtifactPath: lessonPath,
            publishActive: attempt.publishActive,
            sourcePath: canarySource.path,
            configurationPath: canaryContract.path,
            orderKey: attempt.orderKey
          )
        }
      )
    }
    let context = EvaluationFreezeContext(
      repositoryRoot: repository.path,
      manifest: manifest,
      receipt: fixture.context.receipt,
      runtime: fixture.context.runtime,
      runOrderJSON: try makeApprovedEvaluationRunOrderJSON(
        manifestSHA256: fixture.context.receipt.manifest.sha256,
        canaryProcesses: canaryProcesses
      )
    )
    let freezeInputsURL = root.appendingPathComponent("freeze-inputs.json")
    try EvaluationJSONFile.write(fixture.inputs, to: freezeInputsURL)
    try FileManager.default.removeItem(at: fixture.paths.root)
    let seed = PageEvaluationContract.recoveryAccountingSeed
    let observedBudget = Mutex<EvaluationSendBudgetSnapshot?>(nil)
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, _, _ in
      observedBudget.withLock { $0 = invocation.budget }
      return EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
    let conformance = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "conformance_id": "recovery-accounting-test",
      "passed": PageEvaluationContract.conformanceCaseCount,
      "schema_version": 1,
      "total": PageEvaluationContract.conformanceCaseCount,
    ])
    let experiment = EvaluationPageExperiment(
      freezeVerifier: StaticEvaluationFreezeVerifier(context: context),
      artifacts: StaticEvaluationProtectedArtifactRunner(output: conformance),
      launcher: launcher
    )

    // when
    await #expect(throws: EvaluationPagePipelineError.invalidBatch("canary_start_failed")) {
      _ = try await experiment.run(freezeInputsPath: freezeInputsURL.path)
    }

    // then
    let paths = EvaluationController.PagePipelinePaths(
      evaluationRoot: fixture.configurations[0].evaluationRootURL
    )
    let budget = try #require(observedBudget.withLock { $0 })
    #expect(budget.stageResponsesSends == seed.canary.responsesSends)
    #expect(budget.globalResponsesSends == seed.total.responsesSends)
    #expect(budget.stageAccountedTokens == seed.canary.accountedTokens)
    #expect(budget.globalAccountedTokens == seed.total.accountedTokens)
    let summary = try EvaluationJSONFile.decode(
      EvaluationControllerSummary.self,
      from: paths.canarySummary
    )
    #expect(
      summary.attempts
        == seed.canary.attempts + PageEvaluationContract.canaryAttemptsPerProcess
    )
    #expect(summary.fileReads == seed.canary.fileReads)
  }

  @Test(
    arguments: [
      (EvaluationExperimentKind.pageChange, "D6", "D7"),
      (.dependencyPrioritization, "D7", "D6"),
    ]
  )
  func experimentProfilesBindOnlyTheirOwnApprovalDecision(
    kind: EvaluationExperimentKind,
    decision: String,
    mismatchedDecision: String
  ) {
    // given
    let profile = kind.profile
    let otherProfile =
      kind == .pageChange
      ? EvaluationExperimentProfile.dependencyPrioritization
      : .pageChange

    // when
    let matching = EvaluationExperimentProfile.matching(
      decision: decision,
      experiment: kind.rawValue
    )
    let mismatched = EvaluationExperimentProfile.matching(
      decision: mismatchedDecision,
      experiment: kind.rawValue
    )

    // then
    #expect(profile.approvalDecision == decision)
    #expect(matching == profile)
    #expect(mismatched == nil)
    #expect(
      profile.matches(
        decision: otherProfile.approvalDecision,
        experiment: otherProfile.kind.rawValue
      ) == false
    )
  }

  @Test func unknownExperimentCannotSelectAProfile() {
    // given
    let unknownExperiment = "unknown-experiment"

    // when
    let profile = EvaluationExperimentProfile.matching(
      decision: EvaluationExperimentProfile.pageChange.approvalDecision,
      experiment: unknownExperiment
    )

    // then
    #expect(profile == nil)
  }

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
    let observed = cases.map { EvaluationPageTerminalFailureClassifier.failure(for: $0.error) }

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
    let repositoryRoot = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
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

  @Test func freezeManifestRejectsBudgetContractDrift() throws {
    // given — the manifest binds the shared contract; the controller only projects that contract
    // into its stage-specific shape instead of owning another set of literals.
    let validCategory = EvaluationManifestCategory(
      artifacts: [],
      values: PageEvaluationContract.budgetManifestValues,
      sha256: String(repeating: "a", count: 64)
    )
    let valid = EvaluationFreezeManifest(
      schemaVersion: PageEvaluationContract.schemaVersion,
      decision: PageEvaluationContract.profile.approvalDecision,
      experiment: PageEvaluationContract.profile.kind.rawValue,
      categories: ["budget": validCategory],
      protectedArtifacts: []
    )
    var driftedValues = try #require(PageEvaluationContract.budgetManifestValues.objectValue)
    driftedValues["page_attempt_cap"] = .integer(77)
    let drifted = EvaluationFreezeManifest(
      schemaVersion: PageEvaluationContract.schemaVersion,
      decision: PageEvaluationContract.profile.approvalDecision,
      experiment: PageEvaluationContract.profile.kind.rawValue,
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
    try valid.validateBudgetContract(for: .pageChange)
    let driftError = #expect(throws: EvaluationFreezeError.budgetContractMismatch) {
      try drifted.validateBudgetContract(for: .pageChange)
    }

    // then — a decoder that drops budget values would accept the drifted manifest.
    #expect(driftError != nil)
  }
}
