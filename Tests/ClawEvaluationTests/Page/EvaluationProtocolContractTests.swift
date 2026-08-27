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
