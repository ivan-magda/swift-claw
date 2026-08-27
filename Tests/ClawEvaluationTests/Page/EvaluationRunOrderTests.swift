import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationRunOrderTests {
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
    #expect(result.outcome == .invalidBatch)
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
}
