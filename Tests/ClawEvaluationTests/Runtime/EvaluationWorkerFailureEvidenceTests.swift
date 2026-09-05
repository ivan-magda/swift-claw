import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationWorkerFailureEvidenceTests {
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
}
