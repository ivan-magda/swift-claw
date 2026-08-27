import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationPromotionReceiptControllerTests {
  @Test func controllerAuthorizesTheFrozenPromotionReceiptSchema() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let promotion = try makeEvaluationPromotionFixture()
    let fixture = try makePromotionControllerFixture(
      root: root,
      promotion: promotion,
      receiptData: promotion.receiptData
    )

    // when
    try EvaluationController.authorizeAttempt(fixture.configuration, against: fixture.freeze)

    // then — authorization completes without rejecting the frozen producer's binding.
  }

  @Test(
    arguments: [
      "synthesis_prompt_sha256",
      "feedback_generator_version",
      "feedback_generator_sha256",
      "provider_reference",
      "wire_model",
      "selected_target_classes",
    ]
  )
  func controllerRejectsDriftInNewPromotionProvenance(_ field: String) throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let promotion = try makeEvaluationPromotionFixture()
    let receiptData = try promotionReceiptData(
      byDrifting: field,
      from: promotion.receiptData
    )
    let fixture = try makePromotionControllerFixture(
      root: root,
      promotion: promotion,
      receiptData: receiptData
    )

    // when
    let error = #expect(
      throws: EvaluationControllerError.artifactBindingMismatch("promoted_lesson")
    ) {
      try EvaluationController.authorizeAttempt(fixture.configuration, against: fixture.freeze)
    }

    // then
    #expect(error != nil)
  }
}

private struct PromotionControllerFixture {
  let configuration: EvaluationAttemptConfiguration
  let freeze: EvaluationFreezeContext
}

private func makePromotionControllerFixture(
  root: URL,
  promotion: (
    activeLessonData: Data,
    receipt: EvaluationPagePromotionReceipt,
    receiptData: Data
  ),
  receiptData: Data
) throws -> PromotionControllerFixture {
  let evaluation = root.appendingPathComponent("evaluation", isDirectory: true)
  let lessonSets =
    evaluation
    .appendingPathComponent(PageEvaluationContract.stateDirectoryName, isDirectory: true)
    .appendingPathComponent(PageEvaluationContract.lessonSetsDirectoryName, isDirectory: true)
  let lessonURL = lessonSets.appendingPathComponent(
    "\(promotion.receipt.activeLessonSetSHA256).json",
    isDirectory: false
  )
  let receiptURL =
    evaluation
    .appendingPathComponent("receipts", isDirectory: true)
    .appendingPathComponent("promotion.json", isDirectory: false)
  try FileManager.default.createDirectory(at: lessonSets, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: receiptURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try promotion.activeLessonData.write(to: lessonURL)
  try receiptData.write(to: receiptURL)
  let activeLessons = try #require(
    JSONSerialization.jsonObject(with: promotion.activeLessonData) as? [String: Any]
  )
  let configured = try makeEvaluationConfiguration(
    root: root,
    attemptID: "promotion-regression",
    fixtureID: "pc-regression-01",
    split: EvaluationPageSplit.regression.rawValue,
    stage: EvaluationPageStage.regression.rawValue,
    frozenOrderIndex: 1,
    condition: .lessonConditioned,
    lessonSource: .artifact,
    activeLessons: activeLessons,
    lessonArtifactPath: lessonURL.path,
    promotionReceiptPath: receiptURL.path,
    promotionReceiptSHA256: SHA256Digest.hex(receiptData)
  )
  let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
  let freeze = try promotionFreeze(
    frozen.context,
    lessonURL: lessonURL,
    receipt: promotion.receipt,
    configuration: configured.configuration
  )
  return PromotionControllerFixture(configuration: configured.configuration, freeze: freeze)
}

private func promotionFreeze(
  _ freeze: EvaluationFreezeContext,
  lessonURL: URL,
  receipt: EvaluationPagePromotionReceipt,
  configuration: EvaluationAttemptConfiguration
) throws -> EvaluationFreezeContext {
  var categories = freeze.manifest.categories
  let prompts = try #require(categories["prompts"])
  categories["prompts"] = EvaluationManifestCategory(
    artifacts: prompts.artifacts + [
      EvaluationManifestArtifact(
        role: "synthesis",
        path: "prompts/synthesis.md",
        bytes: 1,
        sha256: receipt.synthesisPromptSHA256
      )
    ],
    values: prompts.values,
    sha256: prompts.sha256
  )
  categories["feedback"] = EvaluationManifestCategory(
    artifacts: [],
    sha256: receipt.feedbackGeneratorSHA256
  )
  let repositoryRoot = URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
  let lessonRelativePath = try #require(
    EvaluationPathSecurity.relativePath(of: lessonURL, under: repositoryRoot)
  )
  let manifest = EvaluationFreezeManifest(
    schemaVersion: freeze.manifest.schemaVersion,
    decision: freeze.manifest.decision,
    experiment: freeze.manifest.experiment,
    protocolBinding: freeze.manifest.protocolBinding,
    categories: categories,
    protectedArtifacts: freeze.manifest.protectedArtifacts.filter {
      $0.path != lessonRelativePath
    }
  )
  return EvaluationFreezeContext(
    repositoryRoot: freeze.repositoryRoot,
    manifest: manifest,
    receipt: freeze.receipt,
    runtime: freeze.runtime,
    runOrderJSON: try makeApprovedEvaluationRunOrderJSON(
      manifestSHA256: configuration.approval.manifestSHA256,
      anchor: configuration
    )
  )
}

private func promotionReceiptData(byDrifting field: String, from receiptData: Data) throws -> Data {
  var receipt = try #require(
    JSONSerialization.jsonObject(with: receiptData) as? [String: Any]
  )
  let otherDigest = String(repeating: "b", count: 64)
  switch field {
  case "synthesis_prompt_sha256", "feedback_generator_sha256":
    receipt[field] = otherDigest
  case "feedback_generator_version":
    receipt[field] = "page-feedback-v2"
  case "provider_reference":
    receipt[field] = "other-provider/gpt-5.6-sol"
  case "wire_model":
    receipt[field] = "other-wire-model"
  case "selected_target_classes":
    receipt[field] = [
      "noise.volatile_value",
      "noise.time_or_build_metadata",
    ]
  default:
    Issue.record("Unknown promotion provenance field: \(field)")
  }
  return try EvaluationCanonicalJSON.data(fromJSONObject: receipt)
}
