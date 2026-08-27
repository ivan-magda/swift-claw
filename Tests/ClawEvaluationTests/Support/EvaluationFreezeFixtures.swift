import ClawAgent
import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

func makeEvaluationFreeze(
  root: URL,
  configurations: [EvaluationAttemptConfiguration]
) throws -> (inputs: EvaluationFreezeInputs, context: EvaluationFreezeContext, executable: URL) {
  let repository = root.standardizedFileURL
  let configDirectory = repository.appendingPathComponent("config")
  let runtimeURL = configDirectory.appendingPathComponent("runtime.json")
  let executable = repository.appendingPathComponent("bin/claw-eval")
  let manifestURL = configDirectory.appendingPathComponent("manifest.json")
  let approvalURL = configDirectory.appendingPathComponent("approval.json")
  let approvalBodyURL = configDirectory.appendingPathComponent("approval-body.txt")
  let receiptURL = configurations[0].evaluationRootURL.appendingPathComponent("freeze-receipt.json")
  try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

  let frozenRuntimeURL = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
  ).appendingPathComponent("experiments/scheduled-task-learning/page-change/config/runtime.json")
  var runtimeObject = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: frozenRuntimeURL)) as? [String: Any]
  )
  runtimeObject["evaluation_root"] = configurations[0].evaluationRoot
  runtimeObject["expected_policy_version"] = configurations[0].expectedPolicyVersion
  runtimeObject["task_prompt_path"] = "artifacts/task.md"
  runtimeObject["executable_path"] = "bin/claw-eval"
  runtimeObject["freeze_verifier_path"] = "tools/freeze.py"
  try EvaluationCanonicalJSON.data(fromJSONObject: runtimeObject).write(to: runtimeURL)
  let runtime = try EvaluationRuntimeConfiguration.load(from: runtimeURL)
  let digest = String(repeating: "a", count: 64)
  let runtimeData = try Data(contentsOf: runtimeURL)
  let promptData = try Data(contentsOf: URL(fileURLWithPath: configurations[0].taskPromptPath))
  let artifacts = try configurations.map { configuration in
    let url = URL(fileURLWithPath: configuration.sourceArtifactPath)
    let data = try Data(contentsOf: url)
    return EvaluationManifestProtectedArtifact(
      path: testRelativePath(url, under: repository),
      bytes: data.count,
      sha256: SHA256Digest.hex(data)
    )
  }
  let lessonArtifacts = try configurations.compactMap {
    configuration -> EvaluationManifestProtectedArtifact? in
    guard let path = configuration.lessonArtifactPath else {
      return nil
    }
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return EvaluationManifestProtectedArtifact(
      path: testRelativePath(url, under: repository),
      bytes: data.count,
      sha256: SHA256Digest.hex(data)
    )
  }
  let runtimeArtifact = EvaluationManifestArtifact(
    role: "runtime",
    path: "config/runtime.json",
    bytes: runtimeData.count,
    sha256: SHA256Digest.hex(runtimeData)
  )
  let promptArtifact = EvaluationManifestArtifact(
    role: "task",
    path: "artifacts/task.md",
    bytes: promptData.count,
    sha256: SHA256Digest.hex(promptData)
  )
  let executableArtifact = EvaluationManifestArtifact(
    role: "executable",
    path: "bin/claw-eval",
    bytes: 1,
    sha256: digest
  )
  var categories: [String: EvaluationManifestCategory] = [:]
  for name in [
    "runtime_sources", "harness_sources", "dependencies", "configuration", "model", "retry",
    "output", "prompts", "schemas", "scorer", "splits", "run_order", "executable", "budget",
  ] {
    categories[name] = EvaluationManifestCategory(artifacts: [], sha256: digest)
  }
  categories["budget"] = EvaluationManifestCategory(
    artifacts: [],
    values: PageEvaluationContract.budgetManifestValues,
    sha256: digest
  )
  var configurationArtifacts = [runtimeArtifact]
  if configurations.first?.stage == "canary",
    let sourceConfiguration = configurations.first,
    let cleanConfiguration = configurations.first(where: { $0.lessonSource == .clean }),
    let nonemptyConfiguration = configurations.first(where: { $0.lessonSource == .artifact }),
    let nonemptyPath = nonemptyConfiguration.lessonArtifactPath
  {
    let cleanURL = configDirectory.appendingPathComponent("canary-clean-lessons.json")
    let canaryURL = configDirectory.appendingPathComponent("canary.json")
    let cleanData = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "schema_version": 1, "lesson_set_id": "empty", "lessons": [],
    ])
    try cleanData.write(to: cleanURL)
    let sourceURL = URL(fileURLWithPath: sourceConfiguration.sourceArtifactPath)
    let sourceData = try Data(contentsOf: sourceURL)
    let nonemptyURL = URL(fileURLWithPath: nonemptyPath)
    let nonemptyData = try Data(contentsOf: nonemptyURL)
    let sourceRecord = EvaluationManifestArtifact(
      role: "canary_base_task",
      path: testRelativePath(sourceURL, under: repository),
      bytes: sourceData.count,
      sha256: SHA256Digest.hex(sourceData)
    )
    let cleanRecord = EvaluationManifestArtifact(
      role: "canary_clean_lessons",
      path: testRelativePath(cleanURL, under: repository),
      bytes: cleanData.count,
      sha256: SHA256Digest.hex(cleanData)
    )
    let nonemptyRecord = EvaluationManifestArtifact(
      role: "canary_nonempty_lessons",
      path: testRelativePath(nonemptyURL, under: repository),
      bytes: nonemptyData.count,
      sha256: SHA256Digest.hex(nonemptyData)
    )
    let canaryData = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "schema_version": 1,
      "fixture_id": sourceConfiguration.fixtureID,
      "task_id": sourceConfiguration.taskID,
      "base_task": ["path": sourceRecord.path, "sha256": sourceRecord.sha256],
      "lesson_sets": [
        "clean": ["path": cleanRecord.path, "sha256": cleanRecord.sha256],
        "nonempty": ["path": nonemptyRecord.path, "sha256": nonemptyRecord.sha256],
      ],
      "expected_input_sha256": [
        "clean": cleanConfiguration.inputSHA256,
        "nonempty": nonemptyConfiguration.inputSHA256,
      ],
    ])
    try canaryData.write(to: canaryURL)
    configurationArtifacts += [
      EvaluationManifestArtifact(
        role: "canary",
        path: testRelativePath(canaryURL, under: repository),
        bytes: canaryData.count,
        sha256: SHA256Digest.hex(canaryData)
      ),
      sourceRecord,
      cleanRecord,
      nonemptyRecord,
    ]
  }
  categories["configuration"] = EvaluationManifestCategory(
    artifacts: configurationArtifacts,
    sha256: digest
  )
  categories["prompts"] = EvaluationManifestCategory(
    artifacts: [promptArtifact],
    sha256: digest
  )
  categories["executable"] = EvaluationManifestCategory(
    artifacts: [executableArtifact],
    sha256: digest
  )
  let manifest = EvaluationFreezeManifest(
    categories: categories,
    protectedArtifacts: Array(
      Dictionary(
        grouping: artifacts + lessonArtifacts
          + configurationArtifacts.map {
            EvaluationManifestProtectedArtifact(
              path: $0.path,
              bytes: $0.bytes,
              sha256: $0.sha256
            )
          },
        by: \.path
      ).values.compactMap(\.first)
    )
      + [
        EvaluationManifestProtectedArtifact(
          path: promptArtifact.path,
          bytes: promptArtifact.bytes,
          sha256: promptArtifact.sha256
        )
      ]
  )
  let approval = configurations[0].approval
  let receipt = EvaluationFreezeReceipt(
    schemaVersion: 1,
    status: "verified",
    verifiedAt: "2026-08-26T00:00:00Z",
    decision: "D6",
    experiment: "page-change",
    manifest: EvaluationFreezeReceipt.ManifestBinding(
      path: "config/manifest.json",
      sha256: approval.manifestSHA256
    ),
    verifier: EvaluationFreezeReceipt.FileBinding(
      path: "tools/freeze.py",
      bytes: 1,
      sha256: digest,
      gitMode: "100644",
      format: nil
    ),
    verifierModules: [
      EvaluationFreezeReceipt.FileBinding(
        path: "tools/freeze.py",
        bytes: 1,
        sha256: digest,
        gitMode: "100644",
        format: nil
      )
    ],
    freezeCommit: configurations[0].provenance.freezeCommit,
    comment: EvaluationFreezeReceipt.Comment(
      id: approval.commentID,
      nodeID: approval.commentNodeID,
      author: EvaluationFreezeReceipt.Author(
        login: approval.authorLogin,
        id: approval.authorID,
        nodeID: approval.authorNodeID
      ),
      createdAt: approval.createdAt,
      updatedAt: approval.updatedAt,
      bodySHA256: approval.approvalBodySHA256
    ),
    executable: EvaluationFreezeReceipt.FileBinding(
      path: executableArtifact.path,
      bytes: executableArtifact.bytes,
      sha256: digest,
      gitMode: "100755",
      format: "mach-o-arm64"
    )
  )
  let stages: [[String: Any]]
  if configurations.first?.stage == "canary" {
    stages = [
      [
        "name": "canary",
        "kind": "canary-events",
        "events": configurations.enumerated().map { index, configuration in
          [
            "kind": "attempt",
            "attempt_index": index + 1,
            "fixture_id": configuration.fixtureID,
            "task_id": configuration.taskID,
            "lesson_source": configuration.lessonSource.rawValue,
            "publish_active": configuration.publishLessonAsActive,
            "order_key": configuration.frozenOrderKey,
          ] as [String: Any]
        },
      ]
    ]
  } else {
    stages = [
      [
        "name": configurations.first?.stage ?? "development",
        "kind": "task-attempts",
        "attempts": configurations.enumerated().map { index, configuration in
          [
            "order_index": configuration.frozenOrderIndex,
            "block_index": 0,
            "attempt_order_key": configuration.frozenOrderKey,
            "block_order_key": String(repeating: "b", count: 64),
            "split": configuration.split,
            "fixture_id": configuration.fixtureID,
            "replicate_index": configuration.replicate,
            "condition": configuration.condition.runOrderValue,
            "sequence": index,
          ] as [String: Any]
        },
      ]
    ]
  }
  let order = try EvaluationCanonicalJSON.data(fromJSONObject: ["stages": stages])
  let context = EvaluationFreezeContext(
    repositoryRoot: repository.path,
    manifest: manifest,
    receipt: receipt,
    runtime: runtime,
    runOrderJSON: order
  )
  let inputs = EvaluationFreezeInputs(
    repositoryRoot: repository.path,
    manifestPath: manifestURL.path,
    manifestSHA256: approval.manifestSHA256,
    approvalRecordPath: approvalURL.path,
    approvalBodyPath: approvalBodyURL.path,
    runtimeConfigurationPath: runtimeURL.path,
    receiptPath: receiptURL.path
  )
  return (inputs, context, executable)
}

private func testRelativePath(_ candidate: URL, under root: URL) -> String {
  candidate.standardizedFileURL.pathComponents
    .dropFirst(root.standardizedFileURL.pathComponents.count)
    .joined(separator: "/")
}
