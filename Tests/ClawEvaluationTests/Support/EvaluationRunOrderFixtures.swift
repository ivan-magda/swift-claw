import ClawAgent
import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

func makeApprovedEvaluationRunOrderJSON(
  manifestSHA256: String,
  canaryProcesses suppliedCanaryProcesses: [EvaluationPageCanaryProcessSlot] = [],
  anchor: EvaluationAttemptConfiguration? = nil
) throws -> Data {
  let canaryProcesses =
    suppliedCanaryProcesses.isEmpty
    ? makeApprovedCanaryProcesses(anchor: anchor) : suppliedCanaryProcesses
  var sealedBlockKeys: [String: String] = [:]

  func taskStage(
    stage: EvaluationPageStage,
    fixtureCount: Int,
    conditions: [EvaluationCondition],
    counterbalancePhase: Int?
  ) -> [String: Any] {
    var attempts: [[String: Any]] = []
    var blockIndex = 0
    let split = stage.split.rawValue
    for fixtureIndex in 1...fixtureCount {
      let fixtureID = String(format: "pc-%@-%02d", split, fixtureIndex)
      for replicate in 1...PageEvaluationContract.replicateCount {
        let blockIdentity = "\(fixtureID):\(replicate)"
        let blockKey: String
        if stage == .sealedPostRestart {
          blockKey =
            sealedBlockKeys[blockIdentity]
            ?? SHA256Digest.hex(
              "block:\(EvaluationPageStage.sealedPreRestart.rawValue):\(blockIdentity)"
            )
        } else {
          blockKey = SHA256Digest.hex("block:\(stage.rawValue):\(blockIdentity)")
          if stage == .sealedPreRestart {
            sealedBlockKeys[blockIdentity] = blockKey
          }
        }
        var blockConditions = conditions
        if let counterbalancePhase,
          (blockIndex + counterbalancePhase).isMultiple(of: 2) == false
        {
          blockConditions.reverse()
        }
        for condition in blockConditions {
          let orderIndex = attempts.count
          let isAnchor =
            anchor?.stage == stage.rawValue
            && anchor?.fixtureID == fixtureID
            && anchor?.replicate == replicate
            && anchor?.condition == condition
          let lessonSource: EvaluationLessonSource
          switch condition {
          case .clean: lessonSource = .clean
          case .lessonConditioned: lessonSource = .artifact
          case .postRestartLessonConditioned: lessonSource = .durableActive
          case .synthesis, .canary: lessonSource = .clean
          }
          let orderKey: String
          if isAnchor, let anchor {
            orderKey = anchor.frozenOrderKey
          } else {
            orderKey = SHA256Digest.hex("attempt:\(stage.rawValue):\(orderIndex)")
          }
          attempts.append([
            "attempt_order_key": orderKey,
            "block_index": blockIndex,
            "block_order_key": blockKey,
            "condition": condition.runOrderValue,
            "conversation_policy": "fresh",
            "fixture_id": fixtureID,
            "lesson_source": lessonSource.rawValue,
            "order_index": orderIndex,
            "replicate_index": replicate,
            "split": split,
            "worker_process_key": SHA256Digest.hex("worker:\(stage.rawValue):\(orderIndex)"),
            "workspace_policy": "reset-to-exactly-input-json",
          ])
        }
        blockIndex += 1
      }
    }
    return [
      "attempts": attempts,
      "counterbalance_phase": counterbalancePhase.map { $0 as Any } ?? NSNull(),
      "kind": "task-attempts",
      "name": stage.rawValue,
      "split": split,
      "worker_process_policy": "fresh-os-process-per-attempt",
    ]
  }

  let canaryAttempts = canaryProcesses.flatMap(\.attempts)
  guard canaryAttempts.count == PageEvaluationContract.canaryPlannedAttempts else {
    throw EvaluationPagePipelineError.invalidRunOrder
  }
  let canaryEvents: [[String: Any]] = [
    approvedCanaryEvent(canaryAttempts[0]),
    approvedCanaryEvent(canaryAttempts[1]),
    [
      "barrier": "full-process-restart",
      "from_process": "A",
      "kind": "barrier",
      "order_key": SHA256Digest.hex("canary-restart-barrier"),
      "to_process": "B",
    ],
    approvedCanaryEvent(canaryAttempts[2]),
    approvedCanaryEvent(canaryAttempts[3]),
  ]
  let stages: [[String: Any]] = [
    [
      "attempts_per_worker_process": PageEvaluationContract.canaryAttemptsPerProcess,
      "events": canaryEvents,
      "kind": "canary-events",
      "name": EvaluationPageStage.canary.rawValue,
      "worker_process_count": PageEvaluationContract.canaryProcessCount,
    ],
    taskStage(
      stage: .development,
      fixtureCount: PageEvaluationContract.developmentFixtureCount,
      conditions: [.clean],
      counterbalancePhase: nil
    ),
    [
      "condition": EvaluationCondition.synthesis.runOrderValue,
      "kind": "synthesis-attempt",
      "name": EvaluationPageStage.synthesis.rawValue,
      "order_key": SHA256Digest.hex("synthesis-order"),
      "prompt_path": "prompts/synthesis.md",
      "worker_process_key": SHA256Digest.hex("synthesis-worker"),
      "worker_process_policy": "fresh-os-process",
    ],
    approvedBarrier(
      name: "lesson-freeze-barrier",
      value: "freeze-one-semantic-lesson-set-before-regression"
    ),
    taskStage(
      stage: .regression,
      fixtureCount: PageEvaluationContract.regressionFixtureCount,
      conditions: [.clean, .lessonConditioned],
      counterbalancePhase: 0
    ),
    approvedBarrier(
      name: "regression-unseal-barrier",
      value: "jointly-unseal-both-regression-conditions-and-apply-admission-gate"
    ),
    taskStage(
      stage: .sealedPreRestart,
      fixtureCount: PageEvaluationContract.sealedFixtureCount,
      conditions: [.clean, .lessonConditioned],
      counterbalancePhase: 0
    ),
    approvedBarrier(
      name: "sealed-full-process-restart-barrier",
      value: "publish-flush-exit-release-lock-and-start-new-os-process"
    ),
    taskStage(
      stage: .sealedPostRestart,
      fixtureCount: PageEvaluationContract.sealedFixtureCount,
      conditions: [.postRestartLessonConditioned],
      counterbalancePhase: nil
    ),
    approvedBarrier(
      name: "sealed-joint-unseal-barrier",
      value: "jointly-unseal-clean-lesson-and-post-restart-sealed-conditions"
    ),
  ]
  return try EvaluationCanonicalJSON.data(fromJSONObject: [
    "algorithm": "sha256-length-prefixed-counterbalanced-stage-order",
    "algorithm_version": 2,
    "manifest_sha256": manifestSHA256,
    "planned_attempts": [
      "canary": PageEvaluationContract.canaryPlannedAttempts,
      "page_synthesis": PageEvaluationContract.pageSynthesisPlannedAttempts,
      "page_task": PageEvaluationContract.pageTaskPlannedAttempts,
      "page_task_or_synthesis": PageEvaluationContract.pagePlannedAttempts,
    ],
    "schema_version": 2,
    "stages": stages,
  ])
}

private func makeApprovedCanaryProcesses(
  anchor: EvaluationAttemptConfiguration?
) -> [EvaluationPageCanaryProcessSlot] {
  let fixtureID = anchor?.fixtureID ?? "pc-development-01"
  let taskID = anchor?.taskID ?? "page-000000000001"
  let processKeys = [SHA256Digest.hex("canary-process-a"), SHA256Digest.hex("canary-process-b")]
  let cleanLessonPath = "config/canary-clean-lessons.json"
  let specifications: [(Int, String, String, String, EvaluationLessonSource, String?, Bool)] = [
    (1, "A", processKeys[0], "clean", EvaluationLessonSource.clean, cleanLessonPath, false),
    (
      2,
      "A",
      processKeys[0],
      "nonempty",
      EvaluationLessonSource.artifact,
      "config/canary-nonempty-lessons.json",
      true
    ),
    (3, "B", processKeys[1], "clean", EvaluationLessonSource.clean, cleanLessonPath, false),
    (4, "B", processKeys[1], "nonempty", EvaluationLessonSource.durableActive, nil, false),
  ]
  let attempts = specifications.map {
    index,
    process,
    processKey,
    condition,
    lessonSource,
    lessonPath,
    publish in
    EvaluationPageCanaryAttemptSlot(
      attemptIndex: index,
      fixtureID: fixtureID,
      taskID: taskID,
      process: process,
      workerProcessKey: processKey,
      condition: condition,
      lessonSource: lessonSource,
      lessonArtifactPath: lessonPath,
      publishActive: publish,
      sourcePath: "config/canary-base-task.json",
      configurationPath: "config/canary.json",
      orderKey: SHA256Digest.hex("canary-order-\(index)")
    )
  }
  return [
    EvaluationPageCanaryProcessSlot(
      process: "A",
      workerProcessKey: processKeys[0],
      attempts: Array(attempts.prefix(PageEvaluationContract.canaryAttemptsPerProcess))
    ),
    EvaluationPageCanaryProcessSlot(
      process: "B",
      workerProcessKey: processKeys[1],
      attempts: Array(attempts.suffix(PageEvaluationContract.canaryAttemptsPerProcess))
    ),
  ]
}

private func approvedCanaryEvent(_ slot: EvaluationPageCanaryAttemptSlot) -> [String: Any] {
  [
    "attempt_index": slot.attemptIndex,
    "condition": slot.condition,
    "configuration_path": slot.configurationPath,
    "fixture_id": slot.fixtureID,
    "kind": "attempt",
    "lesson_artifact_path": slot.lessonArtifactPath.map { $0 as Any } ?? NSNull(),
    "lesson_source": slot.lessonSource.rawValue,
    "order_key": slot.orderKey,
    "process": slot.process,
    "publish_active": slot.publishActive,
    "source_path": slot.sourcePath,
    "task_id": slot.taskID,
    "worker_process_key": slot.workerProcessKey,
  ]
}

private func approvedBarrier(name: String, value: String) -> [String: Any] {
  [
    "barrier": value,
    "kind": "barrier",
    "name": name,
    "order_key": SHA256Digest.hex("barrier:\(name)"),
  ]
}
