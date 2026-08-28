import ClawSubprocess
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationPageGateAggregationTests {
  private struct GateOutcomeCase: Sendable {
    let stage: EvaluationPageSplit
    let outcome: String
    let passed: Bool
    let expectedDecision: EvaluationPageGateDecision
  }

  private static let gateOutcomeCases = [
    GateOutcomeCase(
      stage: .development,
      outcome: "development_ready",
      passed: true,
      expectedDecision: .proceed
    ),
    GateOutcomeCase(
      stage: .regression,
      outcome: "regression_promoted",
      passed: true,
      expectedDecision: .proceed
    ),
    GateOutcomeCase(
      stage: .regression,
      outcome: "regression_promoted_not_testable",
      passed: true,
      expectedDecision: .proceed
    ),
    GateOutcomeCase(
      stage: .sealed,
      outcome: "page_validated",
      passed: true,
      expectedDecision: .finish(.pageValidated)
    ),
    GateOutcomeCase(
      stage: .development,
      outcome: "insufficient_development_headroom",
      passed: false,
      expectedDecision: .finish(.insufficientDevelopmentHeadroom)
    ),
    GateOutcomeCase(
      stage: .sealed,
      outcome: "insufficient_sealed_headroom",
      passed: false,
      expectedDecision: .finish(.insufficientSealedHeadroom)
    ),
    GateOutcomeCase(
      stage: .development,
      outcome: "invalid_batch",
      passed: false,
      expectedDecision: .finish(.invalidBatch)
    ),
    GateOutcomeCase(
      stage: .regression,
      outcome: "carrier_failure",
      passed: false,
      expectedDecision: .finish(.carrierFailure)
    ),
    GateOutcomeCase(
      stage: .sealed,
      outcome: "safety_failure",
      passed: false,
      expectedDecision: .finish(.safetyFailure)
    ),
    GateOutcomeCase(
      stage: .development,
      outcome: "page_task_specific_failure",
      passed: false,
      expectedDecision: .finish(.pageTaskSpecificFailure)
    ),
    GateOutcomeCase(
      stage: .sealed,
      outcome: "incomplete_batch",
      passed: false,
      expectedDecision: .finish(.incompleteBatch)
    ),
  ]

  @Test(arguments: gateOutcomeCases)
  private func gateReceiptVocabularyMapsToTheStageDecision(testCase: GateOutcomeCase) async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let receipt = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "result": [
        "outcome": testCase.outcome,
        "passed": testCase.passed,
      ],
      "stage": testCase.stage.rawValue,
    ])
    let artifacts = ScriptedEvaluationProtectedArtifactRunner(output: receipt)
    let launcher = ScriptedEvaluationWorkerLauncher { _, _, _ in
      EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
    let experiment = EvaluationPageExperiment(
      freezeVerifier: StaticEvaluationFreezeVerifier(context: frozen.context),
      artifacts: artifacts,
      launcher: launcher
    )
    let paths = EvaluationController.PagePipelinePaths(
      evaluationRoot: configured.configuration.evaluationRootURL
    )
    let output = root.appendingPathComponent("gate-\(testCase.outcome).json")

    // when
    let status = try await experiment.aggregate(
      stage: testCase.stage,
      records: root.appendingPathComponent("records.json"),
      output: output,
      inputs: frozen.inputs,
      freeze: frozen.context,
      paths: paths
    )

    // then
    #expect(status.decision == testCase.expectedDecision)
    #expect(await launcher.observations.isEmpty)
  }
}
