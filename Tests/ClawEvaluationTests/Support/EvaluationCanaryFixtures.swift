import ClawAgent
import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

struct CanaryControllerFixture {
  let configurations: [EvaluationAttemptConfiguration]
  let inputs: EvaluationFreezeInputs
  let context: EvaluationFreezeContext
  let executable: URL
  let order: EvaluationPageRunOrder
  let paths: EvaluationController.PagePipelinePaths
  let factory: EvaluationPageConfigurationFactory
}

func makeCanaryControllerFixture(root: URL) throws -> CanaryControllerFixture {
  let lessons = try makeEvaluationLessonReloadConfigurations(root: root)
  let configurations = try [
    makeEvaluationConfiguration(
      root: root,
      attemptID: "canary-a-clean",
      stage: EvaluationPageStage.canary.rawValue,
      condition: .canary
    ).configuration,
    lessons.artifact,
    makeEvaluationConfiguration(
      root: root,
      attemptID: "canary-b-clean",
      stage: EvaluationPageStage.canary.rawValue,
      condition: .canary
    ).configuration,
    lessons.durable,
  ]
  let frozen = try makeEvaluationFreeze(root: root, configurations: configurations)
  let digest = configurations[0].protocolSHA256
  let manifest = EvaluationFreezeManifest(
    schemaVersion: PageEvaluationContract.schemaVersion,
    decision: "D6",
    experiment: "page-change",
    protocolBinding: EvaluationManifestProtocolBinding(
      version: "0.2",
      path: "docs/research/118-validation-protocol.md",
      bytes: 1,
      sha256: digest
    ),
    categories: frozen.context.manifest.categories,
    protectedArtifacts: frozen.context.manifest.protectedArtifacts
  )
  let context = EvaluationFreezeContext(
    repositoryRoot: frozen.context.repositoryRoot,
    manifest: manifest,
    receipt: frozen.context.receipt,
    runtime: frozen.context.runtime,
    runOrderJSON: frozen.context.runOrderJSON
  )
  try EvaluationCanonicalJSON.data(fromJSONObject: [
    "comment": ["html_url": configurations[0].approval.approvalCommentURL]
  ]).write(to: URL(fileURLWithPath: frozen.inputs.approvalRecordPath))
  let source = try #require(
    manifest.artifact(role: "canary_base_task", category: "configuration")
  )
  let contract = try #require(manifest.artifact(role: "canary", category: "configuration"))
  let clean = try #require(
    manifest.artifact(role: "canary_clean_lessons", category: "configuration")
  )
  let nonempty = try #require(
    manifest.artifact(role: "canary_nonempty_lessons", category: "configuration")
  )
  let processAKey = SHA256Digest.hex("canary-process-a")
  let processBKey = SHA256Digest.hex("canary-process-b")
  func slot(
    index: Int,
    process: String,
    processKey: String,
    condition: String,
    lessonSource: EvaluationLessonSource,
    lessonPath: String?,
    publish: Bool
  ) -> EvaluationPageCanaryAttemptSlot {
    EvaluationPageCanaryAttemptSlot(
      attemptIndex: index,
      fixtureID: configurations[0].fixtureID,
      taskID: configurations[0].taskID,
      process: process,
      workerProcessKey: processKey,
      condition: condition,
      lessonSource: lessonSource,
      lessonArtifactPath: lessonPath,
      publishActive: publish,
      sourcePath: source.path,
      configurationPath: contract.path,
      orderKey: SHA256Digest.hex("canary-order-\(index)")
    )
  }
  let order = EvaluationPageRunOrder(
    canaryProcesses: [
      EvaluationPageCanaryProcessSlot(
        process: "A",
        workerProcessKey: processAKey,
        attempts: [
          slot(
            index: 1,
            process: "A",
            processKey: processAKey,
            condition: "clean",
            lessonSource: .clean,
            lessonPath: clean.path,
            publish: false
          ),
          slot(
            index: 2,
            process: "A",
            processKey: processAKey,
            condition: "nonempty",
            lessonSource: .artifact,
            lessonPath: nonempty.path,
            publish: true
          ),
        ]
      ),
      EvaluationPageCanaryProcessSlot(
        process: "B",
        workerProcessKey: processBKey,
        attempts: [
          slot(
            index: 3,
            process: "B",
            processKey: processBKey,
            condition: "clean",
            lessonSource: .clean,
            lessonPath: clean.path,
            publish: false
          ),
          slot(
            index: 4,
            process: "B",
            processKey: processBKey,
            condition: "nonempty",
            lessonSource: .durableActive,
            lessonPath: nil,
            publish: false
          ),
        ]
      ),
    ],
    taskSlots: [],
    synthesis: EvaluationPageSynthesisSlot(
      orderKey: SHA256Digest.hex("unused-synthesis"),
      workerProcessKey: SHA256Digest.hex("unused-synthesis-worker"),
      promptPath: "unused"
    )
  )
  let approvedContext = EvaluationFreezeContext(
    repositoryRoot: context.repositoryRoot,
    manifest: context.manifest,
    receipt: context.receipt,
    runtime: context.runtime,
    runOrderJSON: try makeApprovedEvaluationRunOrderJSON(
      manifestSHA256: context.receipt.manifest.sha256,
      canaryProcesses: order.canaryProcesses
    )
  )
  let paths = EvaluationController.PagePipelinePaths(
    evaluationRoot: configurations[0].evaluationRootURL
  )
  try EvaluationPathSecurity.ensurePrivateDirectory(at: paths.configurations)
  try EvaluationPathSecurity.ensurePrivateDirectory(at: paths.results)
  return CanaryControllerFixture(
    configurations: configurations,
    inputs: frozen.inputs,
    context: approvedContext,
    executable: frozen.executable,
    order: order,
    paths: paths,
    factory: EvaluationPageConfigurationFactory(
      freeze: approvedContext,
      freezeInputs: frozen.inputs,
      catalog: EvaluationPageFixtureCatalog(fixtures: [], byID: [:]),
      configurationDirectory: paths.configurations,
      resultDirectory: paths.results
    )
  )
}
