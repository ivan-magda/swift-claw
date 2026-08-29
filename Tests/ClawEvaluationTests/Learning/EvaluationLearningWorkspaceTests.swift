import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationLearningWorkspaceTests {
  @Test func allConditionsEmitTheSameClosedCarrierSchema() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clean = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: "clean",
      split: "regression",
      stage: "regression",
      condition: .clean,
      lessonSource: .clean,
      hasPromotionReceipt: false,
      lessons: []
    )
    let trial = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: "trial",
      split: "regression",
      stage: "regression",
      condition: .lessonConditioned,
      lessonSource: .artifact,
      hasPromotionReceipt: false
    )
    let active = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: "active",
      split: "sealed",
      stage: "sealed-pre-restart",
      condition: .lessonConditioned,
      lessonSource: .artifact,
      hasPromotionReceipt: true
    )
    let restart = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: "restart",
      split: "sealed",
      stage: "sealed-post-restart",
      condition: .postRestartLessonConditioned,
      lessonSource: .durableActive,
      hasPromotionReceipt: true
    )

    // when
    let cleanMaterialization = try EvaluationWorkspaceMaterializer.resetLearning(
      configuration: clean.configuration
    )
    let trialMaterialization = try EvaluationWorkspaceMaterializer.resetLearning(
      configuration: trial.configuration
    )
    let activeMaterialization = try EvaluationWorkspaceMaterializer.resetLearning(
      configuration: active.configuration
    )
    let restartMaterialization = try EvaluationWorkspaceMaterializer.resetLearning(
      configuration: restart.configuration
    )

    // then — routing one condition through the legacy resolver changes this closed schema.
    let materializations = [
      cleanMaterialization,
      trialMaterialization,
      activeMaterialization,
      restartMaterialization,
    ]
    for materialization in materializations {
      try assertClosedCarrierSchema(materialization.workspace.inputPath)
    }
    #expect(cleanMaterialization.workspace.lessonSource == .clean)
    #expect(trialMaterialization.workspace.lessonSource == .artifact)
    #expect(activeMaterialization.workspace.lessonSource == .artifact)
    #expect(restartMaterialization.workspace.lessonSource == .durableActive)
    #expect(cleanMaterialization.lessonSetText == "{\"lessons\":[],\"schema_version\":1}\n")
    #expect(
      cleanMaterialization.workspace.lessonSetDigest
        == "cd3f703ff6473b72c4614896fc174d623a08b3af0ca42771cd4d96615da5cb7b"
    )
    #expect(
      activeMaterialization.workspace.lessonSetDigest
        == restartMaterialization.workspace.lessonSetDigest
    )
  }

  @Test func nonemptyLessonCarrierIsByteExactAndComplete() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = Data(
      """
      {"active_lessons":{"lessons":["First, preserve punctuation: [a]!\\nThen keep order.","Second lesson — café; commas, periods."],"schema_version":1},"schema_version":1,"task":{"after_html":"<section id=\\"after\\">After & done.</section>\\n","before_html":"<main id=\\"before\\">Before \\"quoted\\".</main>\\n","region_ids":["header","body","footer"]},"task_id":"page-000000000001"}

      """.utf8
    )
    let fixture = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: "byte-exact",
      split: "regression",
      stage: "regression",
      condition: .lessonConditioned,
      lessonSource: .artifact,
      hasPromotionReceipt: false,
      carrierDataOverride: expected
    )

    // when
    let materialized = try EvaluationWorkspaceMaterializer.resetLearning(
      configuration: fixture.configuration
    )
    let input = try EvaluationPathSecurity.readRegularSingleLinkFile(
      at: URL(fileURLWithPath: materialized.workspace.inputPath)
    )

    // then — sorting or normalizing the ordered strings changes the materialized carrier.
    #expect(input == expected)
    #expect(materialized.workspace.inputSHA256 == SHA256Digest.hex(expected))
    #expect(materialized.lessonSetText == fixture.lessonSetText)
    #expect(
      SHA256Digest.hex(expected)
        == "b6b1a500545de596430d82eb1b5ef6b615bd5afd1eff567f18ae3000cb6b8c0c"
    )
  }

  @Test(arguments: IncompletePromotedCondition.allCases)
  func activeAndRestartRequireCompletePromotionReceipts(
    _ incomplete: IncompletePromotedCondition
  ) throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: incomplete.rawValue,
      split: "sealed",
      stage: incomplete.isRestart ? "sealed-post-restart" : "sealed-pre-restart",
      condition: incomplete.isRestart ? .postRestartLessonConditioned : .lessonConditioned,
      lessonSource: incomplete.isRestart ? .durableActive : .artifact,
      hasPromotionReceipt: false
    )
    let receiptURL = root.appendingPathComponent("partial-promotion-receipt.json")
    let receiptData = try EvaluationCanonicalJSON.data(fromJSONObject: ["schema_version": 1])
    try receiptData.write(to: receiptURL)
    var configurationObject = try #require(
      JSONSerialization.jsonObject(
        with: EvaluationCanonicalJSON.data(encoding: fixture.configuration)
      ) as? [String: Any]
    )
    if incomplete.hasPath {
      configurationObject["promotion_receipt_path"] = receiptURL.path
    }
    if incomplete.hasDigest {
      configurationObject["promotion_receipt_sha256"] = SHA256Digest.hex(receiptData)
    }
    let candidate = try JSONDecoder().decode(
      EvaluationAttemptConfiguration.self,
      from: EvaluationCanonicalJSON.data(fromJSONObject: configurationObject)
    )

    // when
    let error = #expect(throws: EvaluationConfigurationError.invalidLessonSource) {
      try candidate.validate()
    }

    // then — each promoted condition requires both independently frozen receipt fields.
    #expect(error != nil)
  }

  @Test func restartRejectsACanonicalCarrierWithAStaleLessonDigest() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let staleDigest = String(repeating: "f", count: 64)
    let fixture = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: "restart-stale-lesson-digest",
      split: "sealed",
      stage: "sealed-post-restart",
      condition: .postRestartLessonConditioned,
      lessonSource: .durableActive,
      hasPromotionReceipt: true,
      expectedLessonSetDigest: staleDigest
    )
    let observedDigest = SHA256Digest.hex(Data(fixture.lessonSetText.utf8))

    // when
    let error = #expect(throws: EvaluationWorkspaceError.self) {
      _ = try EvaluationWorkspaceMaterializer.resetLearning(
        configuration: fixture.configuration
      )
    }

    // then — omitting the common carrier/configuration digest guard admits stale restart input.
    guard case .lessonDigestMismatch(let expected, let observed) = error else {
      Issue.record("restart carrier did not fail at the common lesson digest binding")
      return
    }
    #expect(expected == staleDigest)
    #expect(observed == observedDigest)
  }

  @Test(arguments: PromotionReceiptMutation.allCases)
  func activeAndRestartRejectMissingOrChangedPromotionReceiptBytes(
    _ mutation: PromotionReceiptMutation
  ) throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: mutation.rawValue,
      split: "sealed",
      stage: mutation.isRestart ? "sealed-post-restart" : "sealed-pre-restart",
      condition: mutation.isRestart ? .postRestartLessonConditioned : .lessonConditioned,
      lessonSource: mutation.isRestart ? .durableActive : .artifact,
      hasPromotionReceipt: true
    )
    let receiptPath = try #require(fixture.configuration.promotionReceiptPath)
    let receiptURL = URL(fileURLWithPath: receiptPath)
    if mutation.isMissing {
      try FileManager.default.removeItem(at: receiptURL)
    } else {
      try Data("changed promotion receipt".utf8).write(to: receiptURL)
    }
    let workspace = fixture.configuration.workspaceRootURL
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let sentinel = workspace.appendingPathComponent("preexisting.txt")
    try Data("preserve".utf8).write(to: sentinel)

    // when
    let error = #expect(throws: (any Error).self) {
      _ = try EvaluationWorkspaceMaterializer.resetLearning(
        configuration: fixture.configuration
      )
    }

    // then — skipping either live receipt guard publishes a workspace from stale provenance.
    if mutation.isMissing {
      #expect(
        error as? EvaluationPathSecurityError == .unavailable(receiptURL.lastPathComponent)
      )
    } else {
      #expect(
        error as? EvaluationPromotionReceiptError
          == .digestMismatch(
            expected: try #require(fixture.configuration.promotionReceiptSHA256),
            observed: SHA256Digest.hex(Data("changed promotion receipt".utf8))
          )
      )
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: workspace.path) == ["preexisting.txt"]
    )
  }

  @Test func cleanRejectsANoncanonicalEmptySet() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let noncanonical = Data(
      """
      {"active_lessons":{"schema_version":1,"lessons":[]},"schema_version":1,"task":{"after_html":"<section id=\\"after\\">After & done.</section>\\n","before_html":"<main id=\\"before\\">Before \\"quoted\\".</main>\\n","region_ids":["header","body","footer"]},"task_id":"page-000000000001"}

      """.utf8
    )
    let fixture = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: "noncanonical-clean",
      split: "regression",
      stage: "regression",
      condition: .clean,
      lessonSource: .clean,
      hasPromotionReceipt: false,
      lessons: [],
      carrierDataOverride: noncanonical
    )

    // when
    let error = #expect(throws: (any Error).self) {
      _ = try EvaluationWorkspaceMaterializer.resetLearning(configuration: fixture.configuration)
    }

    // then — decoding semantic JSON without the canonical-byte check accepts reordered fields.
    #expect(error != nil)
  }

  @Test(arguments: [
    "clean-path-only",
    "clean-digest-only",
    "trial-path-only",
    "trial-digest-only",
  ])
  func cleanAndTrialRejectPartialPromotionReceipts(_ variation: String) throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let isClean = variation.hasPrefix("clean-")
    let fixture = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: variation,
      split: "regression",
      stage: "regression",
      condition: isClean ? .clean : .lessonConditioned,
      lessonSource: isClean ? .clean : .artifact,
      hasPromotionReceipt: false,
      lessons: isClean ? [] : ["candidate lesson"]
    )
    var configuration = try #require(
      JSONSerialization.jsonObject(
        with: EvaluationCanonicalJSON.data(encoding: fixture.configuration)
      ) as? [String: Any]
    )
    if variation.hasSuffix("path-only") {
      configuration["promotion_receipt_path"] = root.appendingPathComponent("receipt.json").path
    } else {
      configuration["promotion_receipt_sha256"] = String(repeating: "c", count: 64)
    }
    let candidate = try JSONDecoder().decode(
      EvaluationAttemptConfiguration.self,
      from: EvaluationCanonicalJSON.data(fromJSONObject: configuration)
    )

    // when
    let error = #expect(throws: EvaluationConfigurationError.invalidLessonSource) {
      try candidate.validate()
    }

    // then — treating a one-sided receipt as absent loses frozen promotion provenance.
    #expect(error != nil)
  }

  @Test func lessonSetRejectsClosedSchemaAndBoundViolations() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeLearningWorkspaceFixture(
      root: root,
      attemptID: "closed-schema",
      split: "regression",
      stage: "regression",
      condition: .clean,
      lessonSource: .clean,
      hasPromotionReceipt: false,
      lessons: []
    )
    let cases = invalidCarrierCases(task: fixture.task)

    // when
    let errors = try cases.enumerated().map { index, item in
      let url = root.appendingPathComponent("invalid-carrier-\(index).json")
      try EvaluationCanonicalJSON.data(fromJSONObject: item.carrier).write(to: url)
      return #expect(throws: (any Error).self) {
        _ = try EvaluationLearningTaskCarrier.loadCanonical(from: url)
      }
    }

    // then — Codable alone ignores unknown keys and each omitted bound admits malformed input.
    #expect(errors.allSatisfy { $0 != nil })
  }

  @Test func legacyNilProfileEncodingRemainsByteExact() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let original = try EvaluationCanonicalJSON.data(encoding: configured.configuration)
    let keys = try #require(
      JSONSerialization.jsonObject(with: original) as? [String: Any]
    ).keys

    // when
    let decoded = try JSONDecoder().decode(EvaluationAttemptConfiguration.self, from: original)
    let reencoded = try EvaluationCanonicalJSON.data(encoding: decoded)

    // then — encoding absent M3 optionals as null changes legacy frozen bytes.
    #expect(Set(keys).isDisjoint(with: ["execution_profile", "carrier_path", "carrier_sha256"]))
    #expect(reencoded == original)
  }
}

private struct LearningWorkspaceFixture {
  let configuration: EvaluationAttemptConfiguration
  let lessonSetText: String
  let task: [String: Any]
}

enum IncompletePromotedCondition: String, CaseIterable, Sendable {
  case activeMissing = "active-missing"
  case activePathOnly = "active-path-only"
  case activeDigestOnly = "active-digest-only"
  case restartMissing = "restart-missing"
  case restartPathOnly = "restart-path-only"
  case restartDigestOnly = "restart-digest-only"

  var isRestart: Bool {
    rawValue.hasPrefix("restart-")
  }

  var hasPath: Bool {
    rawValue.hasSuffix("path-only")
  }

  var hasDigest: Bool {
    rawValue.hasSuffix("digest-only")
  }
}

enum PromotionReceiptMutation: String, CaseIterable, Sendable {
  case activeMissing = "active-receipt-missing"
  case activeChanged = "active-receipt-changed"
  case restartMissing = "restart-receipt-missing"
  case restartChanged = "restart-receipt-changed"

  var isRestart: Bool {
    rawValue.hasPrefix("restart-")
  }

  var isMissing: Bool {
    rawValue.hasSuffix("-missing")
  }
}

private func makeLearningWorkspaceFixture(
  root: URL,
  attemptID: String,
  split: String,
  stage: String,
  condition: EvaluationCondition,
  lessonSource: EvaluationLessonSource,
  hasPromotionReceipt: Bool,
  lessons: [String] = [
    "First, preserve punctuation: [a]!\nThen keep order.",
    "Second lesson — café; commas, periods.",
  ],
  carrierDataOverride: Data? = nil,
  expectedLessonSetDigest: String? = nil
) throws -> LearningWorkspaceFixture {
  let artifacts = root.appendingPathComponent("learning-artifacts", isDirectory: true)
  try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
  let task: [String: Any] = [
    "after_html": "<section id=\"after\">After & done.</section>\n",
    "before_html": "<main id=\"before\">Before \"quoted\".</main>\n",
    "region_ids": ["header", "body", "footer"],
  ]
  let lessonSet: [String: Any] = [
    "lessons": lessons,
    "schema_version": 1,
  ]
  let lessonSetData = try EvaluationCanonicalJSON.data(fromJSONObject: lessonSet)
  let carrierData =
    try carrierDataOverride
    ?? EvaluationCanonicalJSON.data(fromJSONObject: [
      "active_lessons": lessonSet,
      "schema_version": 1,
      "task": task,
      "task_id": "page-000000000001",
    ])
  let carrierURL = artifacts.appendingPathComponent("\(attemptID)-carrier.json")
  try carrierData.write(to: carrierURL)
  let receiptURL = artifacts.appendingPathComponent("\(attemptID)-promotion.json")
  let receiptData = try EvaluationCanonicalJSON.data(fromJSONObject: ["schema_version": 1])
  if hasPromotionReceipt {
    try receiptData.write(to: receiptURL)
  }
  let configured = try makeEvaluationConfiguration(
    root: root,
    executionProfile: .scheduledLearningV1,
    carrierPath: carrierURL.path,
    carrierSHA256: SHA256Digest.hex(carrierData),
    attemptID: attemptID,
    split: split,
    stage: stage,
    condition: condition,
    lessonSource: lessonSource,
    activeLessons: lessonSet,
    task: task,
    inputSHA256: SHA256Digest.hex(carrierData),
    lessonSetDigestOverride: expectedLessonSetDigest,
    promotionReceiptPath: hasPromotionReceipt ? receiptURL.path : nil,
    promotionReceiptSHA256: hasPromotionReceipt ? SHA256Digest.hex(receiptData) : nil
  )
  return LearningWorkspaceFixture(
    configuration: configured.configuration,
    lessonSetText: String(decoding: lessonSetData, as: UTF8.self),
    task: task
  )
}

private func assertClosedCarrierSchema(_ inputPath: String) throws {
  let input = try EvaluationPathSecurity.readRegularSingleLinkFile(
    at: URL(fileURLWithPath: inputPath)
  )
  let carrier = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
  let activeLessons = try #require(carrier["active_lessons"] as? [String: Any])
  let task = try #require(carrier["task"] as? [String: Any])
  #expect(Set(carrier.keys) == ["active_lessons", "schema_version", "task", "task_id"])
  #expect(Set(activeLessons.keys) == ["lessons", "schema_version"])
  #expect(Set(task.keys) == ["before_html", "after_html", "region_ids"])
}

private func invalidCarrierCases(task: [String: Any]) -> [(name: String, carrier: [String: Any])] {
  let validLessons: [String: Any] = ["lessons": [], "schema_version": 1]
  let validCarrier: [String: Any] = [
    "active_lessons": validLessons,
    "schema_version": 1,
    "task": task,
    "task_id": "page-000000000001",
  ]
  var unknownTopLevel = validCarrier
  unknownTopLevel["unexpected"] = true
  var nestedTask = task
  nestedTask["unexpected"] = true
  var unknownNested = validCarrier
  unknownNested["task"] = nestedTask
  return [
    ("unknown-top-level", unknownTopLevel),
    ("unknown-nested", unknownNested),
    (
      "wrong-schema-version",
      carrier(task: task, lessons: [], schemaVersion: 2)
    ),
    (
      "four-lessons",
      carrier(task: task, lessons: ["one", "two", "three", "four"], schemaVersion: 1)
    ),
    ("empty-lesson", carrier(task: task, lessons: [""], schemaVersion: 1)),
    ("duplicate-lesson", carrier(task: task, lessons: ["same", "same"], schemaVersion: 1)),
    (
      "oversized-lesson",
      carrier(task: task, lessons: [String(repeating: "a", count: 513)], schemaVersion: 1)
    ),
  ]
}

private func carrier(task: [String: Any], lessons: [String], schemaVersion: Int) -> [String: Any] {
  [
    "active_lessons": ["lessons": lessons, "schema_version": schemaVersion],
    "schema_version": 1,
    "task": task,
    "task_id": "page-000000000001",
  ]
}
