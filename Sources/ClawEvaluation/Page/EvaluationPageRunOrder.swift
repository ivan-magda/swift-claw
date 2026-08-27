import ClawAgent
import ClawCore
import Foundation

enum EvaluationPageSplit: String, Sendable, Equatable {
  case development
  case regression
  case sealed
}

enum EvaluationPageStage: String, Sendable, Equatable {
  case canary
  case development
  case synthesis
  case regression
  case sealedPreRestart = "sealed-pre-restart"
  case sealedPostRestart = "sealed-post-restart"

  var split: EvaluationPageSplit {
    switch self {
    case .canary, .development, .synthesis: .development
    case .regression: .regression
    case .sealedPreRestart, .sealedPostRestart: .sealed
    }
  }
}

struct EvaluationPageTaskSlot: Sendable, Equatable {
  let stage: String
  let split: String
  let orderIndex: Int
  let blockIndex: Int
  let orderKey: String
  let blockOrderKey: String
  let fixtureID: String
  let replicate: Int
  let condition: String
  let lessonSource: EvaluationLessonSource
  let workerProcessKey: String
}

struct EvaluationPageSynthesisSlot: Sendable, Equatable {
  let orderKey: String
  let workerProcessKey: String
  let promptPath: String
}

struct EvaluationPageBarrierSlot: Sendable, Equatable {
  let name: String
  let barrier: String
  let orderKey: String
}

struct EvaluationPageCanaryAttemptSlot: Sendable, Equatable {
  let attemptIndex: Int
  let fixtureID: String
  let taskID: String
  let process: String
  let workerProcessKey: String
  let condition: String
  let lessonSource: EvaluationLessonSource
  let lessonArtifactPath: String?
  let publishActive: Bool
  let sourcePath: String
  let configurationPath: String
  let orderKey: String
}

struct EvaluationPageCanaryProcessSlot: Sendable, Equatable {
  let process: String
  let workerProcessKey: String
  let attempts: [EvaluationPageCanaryAttemptSlot]
}

private struct EvaluationPageTaskStageExpectations {
  let conditions: [String]
  let attemptCount: Int
  let fixtureCount: Int
}

struct EvaluationPageRunOrder: Sendable, Equatable {
  let canaryProcesses: [EvaluationPageCanaryProcessSlot]
  let taskSlots: [EvaluationPageTaskSlot]
  let synthesis: EvaluationPageSynthesisSlot

  func restartLifecycleSlots() throws -> (
    publisher: EvaluationPageTaskSlot,
    firstReload: EvaluationPageTaskSlot
  ) {
    let preRestart = taskSlots.filter {
      $0.stage == EvaluationPageStage.sealedPreRestart.rawValue
    }
    let postRestart = taskSlots.filter {
      $0.stage == EvaluationPageStage.sealedPostRestart.rawValue
    }
    guard
      let publisher = preRestart.last(where: {
        $0.condition == EvaluationCondition.lessonConditioned.runOrderValue
          && $0.lessonSource == .artifact
      }),
      let firstReload = postRestart.first,
      firstReload.condition == EvaluationCondition.postRestartLessonConditioned.runOrderValue,
      firstReload.lessonSource == .durableActive
    else { throw EvaluationPagePipelineError.invalidRunOrder }
    return (publisher, firstReload)
  }

  static func decode(_ data: Data, approvedManifestSHA256: String) throws -> Self {
    let stages = try decodeStageDictionaries(data, approvedManifestSHA256: approvedManifestSHA256)
    return try decodeRunOrder(stages)
  }

  static func validateTaskStage(
    name: String,
    split: String,
    counterbalancePhase: Int?,
    slots: [EvaluationPageTaskSlot]
  ) throws {
    guard
      let stage = EvaluationPageStage(rawValue: name),
      let typedSplit = EvaluationPageSplit(rawValue: split),
      stage.split == typedSplit
    else { throw EvaluationPagePipelineError.invalidRunOrder }
    let expectations = try taskStageExpectations(stage, counterbalancePhase: counterbalancePhase)
    try validateTaskSlots(slots, split: split, expectations: expectations)
    try validateTaskBlocks(
      slots,
      counterbalancePhase: counterbalancePhase,
      expectations: expectations
    )
    try validateTaskReplicates(slots)
  }

  static func validateBarriers(_ barriers: [EvaluationPageBarrierSlot]) -> Bool {
    let expected = [
      ("lesson-freeze-barrier", "freeze-one-semantic-lesson-set-before-regression"),
      (
        "regression-unseal-barrier",
        "jointly-unseal-both-regression-conditions-and-apply-admission-gate"
      ),
      (
        "sealed-full-process-restart-barrier",
        "publish-flush-exit-release-lock-and-start-new-os-process"
      ),
      (
        "sealed-joint-unseal-barrier",
        "jointly-unseal-clean-lesson-and-post-restart-sealed-conditions"
      ),
    ]
    return barriers.count == expected.count
      && zip(barriers, expected).allSatisfy { barrier, expected in
        barrier.name == expected.0
          && barrier.barrier == expected.1
          && SHA256Digest.isCanonicalHex(barrier.orderKey)
      }
      && Set(barriers.map(\.orderKey)).count == barriers.count
  }
}

// MARK: - Run Order Decoding

private extension EvaluationPageRunOrder {
  static func decodeStageDictionaries(
    _ data: Data,
    approvedManifestSHA256: String
  ) throws -> [[String: Any]] {
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      CanonicalJSON.integer(root["schema_version"]) == 2,
      root["algorithm"] as? String == "sha256-length-prefixed-counterbalanced-stage-order",
      CanonicalJSON.integer(root["algorithm_version"]) == 2,
      root["manifest_sha256"] as? String == approvedManifestSHA256,
      let planned = root["planned_attempts"] as? [String: Any],
      CanonicalJSON.integer(planned["canary"]) == PageEvaluationContract.canaryPlannedAttempts,
      CanonicalJSON.integer(planned["page_task"])
        == PageEvaluationContract.pageTaskPlannedAttempts,
      CanonicalJSON.integer(planned["page_synthesis"])
        == PageEvaluationContract.pageSynthesisPlannedAttempts,
      CanonicalJSON.integer(planned["page_task_or_synthesis"])
        == PageEvaluationContract.pagePlannedAttempts,
      let stages = root["stages"] as? [[String: Any]]
    else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }

    let expectedNames = [
      "canary", "development", "synthesis", "lesson-freeze-barrier", "regression",
      "regression-unseal-barrier", "sealed-pre-restart",
      "sealed-full-process-restart-barrier", "sealed-post-restart",
      "sealed-joint-unseal-barrier",
    ]
    guard stages.compactMap({ $0["name"] as? String }) == expectedNames else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    return stages
  }

  static func decodeRunOrder(_ stages: [[String: Any]]) throws -> Self {
    var taskSlots: [EvaluationPageTaskSlot] = []
    var canaryProcesses: [EvaluationPageCanaryProcessSlot] = []
    var synthesis: EvaluationPageSynthesisSlot?
    var barriers: [EvaluationPageBarrierSlot] = []
    for stage in stages {
      guard let kind = stage["kind"] as? String, let name = stage["name"] as? String else {
        throw EvaluationPagePipelineError.invalidRunOrder
      }
      switch kind {
      case "canary-events":
        canaryProcesses = try decodeCanaryProcesses(stage, name: name)
      case "task-attempts":
        taskSlots.append(contentsOf: try decodeTaskSlots(stage, name: name))
      case "synthesis-attempt":
        synthesis = try decodeSynthesis(stage, name: name)
      case "barrier":
        barriers.append(try decodeBarrier(stage, name: name))
      default:
        throw EvaluationPagePipelineError.invalidRunOrder
      }
    }
    guard let synthesis else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    try validateRunOrder(
      canaryProcesses: canaryProcesses,
      taskSlots: taskSlots,
      synthesis: synthesis,
      barriers: barriers
    )
    return Self(
      canaryProcesses: canaryProcesses,
      taskSlots: taskSlots,
      synthesis: synthesis
    )
  }

  static func decodeSynthesis(
    _ stage: [String: Any],
    name: String
  ) throws -> EvaluationPageSynthesisSlot {
    guard
      name == "synthesis",
      stage["condition"] as? String == "synthesis",
      stage["worker_process_policy"] as? String == "fresh-os-process",
      let orderKey = stage["order_key"] as? String,
      let workerProcessKey = stage["worker_process_key"] as? String,
      let promptPath = stage["prompt_path"] as? String
    else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    return EvaluationPageSynthesisSlot(
      orderKey: orderKey,
      workerProcessKey: workerProcessKey,
      promptPath: promptPath
    )
  }

  static func decodeBarrier(
    _ stage: [String: Any],
    name: String
  ) throws -> EvaluationPageBarrierSlot {
    guard
      let barrier = stage["barrier"] as? String,
      let orderKey = stage["order_key"] as? String
    else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    return EvaluationPageBarrierSlot(name: name, barrier: barrier, orderKey: orderKey)
  }
}

// MARK: - Canary Decoding

private extension EvaluationPageRunOrder {
  static func decodeCanaryProcesses(
    _ stage: [String: Any],
    name: String
  ) throws -> [EvaluationPageCanaryProcessSlot] {
    guard
      name == "canary",
      CanonicalJSON.integer(stage["worker_process_count"])
        == PageEvaluationContract.canaryProcessCount,
      CanonicalJSON.integer(stage["attempts_per_worker_process"])
        == PageEvaluationContract.canaryAttemptsPerProcess,
      let events = stage["events"] as? [[String: Any]],
      events.count == PageEvaluationContract.canaryEventCount,
      events[2]["kind"] as? String == "barrier",
      events[2]["barrier"] as? String == "full-process-restart",
      events[2]["from_process"] as? String == "A",
      events[2]["to_process"] as? String == "B",
      events[2]["order_key"] is String
    else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    let attemptEvents = [events[0], events[1], events[3], events[4]]
    let attempts = try attemptEvents.map(canaryAttempt)
    guard validateCanaryAttempts(attempts) else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    return [
      EvaluationPageCanaryProcessSlot(
        process: "A",
        workerProcessKey: attempts[0].workerProcessKey,
        attempts: Array(attempts.prefix(PageEvaluationContract.canaryAttemptsPerProcess))
      ),
      EvaluationPageCanaryProcessSlot(
        process: "B",
        workerProcessKey: attempts[2].workerProcessKey,
        attempts: Array(attempts.suffix(PageEvaluationContract.canaryAttemptsPerProcess))
      ),
    ]
  }

  static func canaryAttempt(_ event: [String: Any]) throws -> EvaluationPageCanaryAttemptSlot {
    guard
      event["kind"] as? String == "attempt",
      let attemptIndex = CanonicalJSON.integer(event["attempt_index"]),
      let fixtureID = event["fixture_id"] as? String,
      let taskID = event["task_id"] as? String,
      let process = event["process"] as? String,
      let workerProcessKey = event["worker_process_key"] as? String,
      let condition = event["condition"] as? String,
      let sourceValue = event["lesson_source"] as? String,
      let lessonSource = EvaluationLessonSource(rawValue: sourceValue),
      let publishActive = CanonicalJSON.boolean(event["publish_active"]),
      let sourcePath = event["source_path"] as? String,
      let configurationPath = event["configuration_path"] as? String,
      let orderKey = event["order_key"] as? String
    else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    return EvaluationPageCanaryAttemptSlot(
      attemptIndex: attemptIndex,
      fixtureID: fixtureID,
      taskID: taskID,
      process: process,
      workerProcessKey: workerProcessKey,
      condition: condition,
      lessonSource: lessonSource,
      lessonArtifactPath: event["lesson_artifact_path"] as? String,
      publishActive: publishActive,
      sourcePath: sourcePath,
      configurationPath: configurationPath,
      orderKey: orderKey
    )
  }

  static func validateCanaryAttempts(_ attempts: [EvaluationPageCanaryAttemptSlot]) -> Bool {
    let processAttemptCount = PageEvaluationContract.canaryAttemptsPerProcess
    return attempts.map(\.attemptIndex) == Array(1...PageEvaluationContract.canaryPlannedAttempts)
      && attempts.map(\.process) == ["A", "A", "B", "B"]
      && attempts.map(\.condition) == ["clean", "nonempty", "clean", "nonempty"]
      && attempts.map(\.lessonSource) == [.clean, .artifact, .clean, .durableActive]
      && attempts.map(\.publishActive) == [false, true, false, false]
      && Set(attempts.map(\.fixtureID)).count == 1
      && Set(attempts.map(\.taskID)).count == 1
      && Set(attempts.map(\.sourcePath)).count == 1
      && Set(attempts.map(\.configurationPath)).count == 1
      && Set(attempts.prefix(processAttemptCount).map(\.workerProcessKey)).count == 1
      && Set(attempts.suffix(processAttemptCount).map(\.workerProcessKey)).count == 1
      && attempts[0].workerProcessKey != attempts[2].workerProcessKey
      && attempts.allSatisfy({ SHA256Digest.isCanonicalHex($0.orderKey) })
      && attempts.allSatisfy({ SHA256Digest.isCanonicalHex($0.workerProcessKey) })
      && Set(attempts.map(\.orderKey)).count == attempts.count
      && attempts[0].lessonArtifactPath != nil
      && attempts[0].lessonArtifactPath == attempts[2].lessonArtifactPath
      && attempts[1].lessonArtifactPath != nil
      && attempts[3].lessonArtifactPath == nil
  }
}

// MARK: - Task Decoding

private extension EvaluationPageRunOrder {
  static func decodeTaskSlots(
    _ stage: [String: Any],
    name: String
  ) throws -> [EvaluationPageTaskSlot] {
    guard let taskStage = EvaluationPageStage(rawValue: name) else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    let counterbalancePhase = try decodeCounterbalancePhase(stage, taskStage: taskStage)
    guard
      stage["worker_process_policy"] as? String == "fresh-os-process-per-attempt",
      let split = stage["split"] as? String,
      let attempts = stage["attempts"] as? [[String: Any]]
    else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    let slots = try attempts.map {
      try decodeTaskSlot($0, stageName: name, split: split)
    }
    try validateTaskStage(
      name: name,
      split: split,
      counterbalancePhase: counterbalancePhase,
      slots: slots
    )
    return slots
  }

  static func decodeCounterbalancePhase(
    _ stage: [String: Any],
    taskStage: EvaluationPageStage
  ) throws -> Int? {
    switch taskStage {
    case .development, .sealedPostRestart:
      guard stage["counterbalance_phase"] is NSNull else {
        throw EvaluationPagePipelineError.invalidRunOrder
      }
      return nil
    case .regression, .sealedPreRestart:
      guard
        let phase = CanonicalJSON.integer(stage["counterbalance_phase"]),
        (0...1).contains(phase)
      else { throw EvaluationPagePipelineError.invalidRunOrder }
      return phase
    case .canary, .synthesis:
      throw EvaluationPagePipelineError.invalidRunOrder
    }
  }

  static func decodeTaskSlot(
    _ attempt: [String: Any],
    stageName: String,
    split: String
  ) throws -> EvaluationPageTaskSlot {
    guard
      attempt["conversation_policy"] as? String == "fresh",
      attempt["workspace_policy"] as? String == "reset-to-exactly-input-json",
      let orderIndex = CanonicalJSON.integer(attempt["order_index"]),
      let blockIndex = CanonicalJSON.integer(attempt["block_index"]),
      let orderKey = attempt["attempt_order_key"] as? String,
      let blockOrderKey = attempt["block_order_key"] as? String,
      let fixtureID = attempt["fixture_id"] as? String,
      let replicate = CanonicalJSON.integer(attempt["replicate_index"]),
      let condition = attempt["condition"] as? String,
      let source = attempt["lesson_source"] as? String,
      let lessonSource = EvaluationLessonSource(rawValue: source),
      let workerProcessKey = attempt["worker_process_key"] as? String,
      split == attempt["split"] as? String
    else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    return EvaluationPageTaskSlot(
      stage: stageName,
      split: split,
      orderIndex: orderIndex,
      blockIndex: blockIndex,
      orderKey: orderKey,
      blockOrderKey: blockOrderKey,
      fixtureID: fixtureID,
      replicate: replicate,
      condition: condition,
      lessonSource: lessonSource,
      workerProcessKey: workerProcessKey
    )
  }
}

// MARK: - Run Order Validation

private extension EvaluationPageRunOrder {
  static func validateRunOrder(
    canaryProcesses: [EvaluationPageCanaryProcessSlot],
    taskSlots: [EvaluationPageTaskSlot],
    synthesis: EvaluationPageSynthesisSlot,
    barriers: [EvaluationPageBarrierSlot]
  ) throws {
    let canaryAttempts = canaryProcesses.flatMap(\.attempts)
    let allDerivedKeys =
      taskSlots.flatMap { [$0.orderKey, $0.workerProcessKey] }
      + [synthesis.orderKey, synthesis.workerProcessKey]
      + barriers.map(\.orderKey)
      + canaryAttempts.map(\.orderKey)
      + Array(Set(canaryAttempts.map(\.workerProcessKey)))
    guard
      taskSlots.count == PageEvaluationContract.pageTaskPlannedAttempts,
      taskSlots.filter({ $0.stage == EvaluationPageStage.development.rawValue }).count
        == PageEvaluationContract.pageDevelopmentPlannedAttempts,
      taskSlots.filter({ $0.stage == EvaluationPageStage.regression.rawValue }).count
        == PageEvaluationContract.pageRegressionPlannedAttempts,
      taskSlots.filter({ $0.stage == EvaluationPageStage.sealedPreRestart.rawValue }).count
        == PageEvaluationContract.pageSealedPreRestartPlannedAttempts,
      taskSlots.filter({ $0.stage == EvaluationPageStage.sealedPostRestart.rawValue }).count
        == PageEvaluationContract.pageSealedPostRestartPlannedAttempts,
      canaryProcesses.count == PageEvaluationContract.canaryProcessCount,
      SHA256Digest.isCanonicalHex(synthesis.orderKey),
      SHA256Digest.isCanonicalHex(synthesis.workerProcessKey),
      Set(taskSlots.map(\.orderKey)).count == taskSlots.count,
      Set(taskSlots.map(\.workerProcessKey)).count == taskSlots.count,
      Set(taskSlots.map(\.blockOrderKey)).count == PageEvaluationContract.pageUniqueBlockCount,
      Set(allDerivedKeys).count == allDerivedKeys.count,
      validateBarriers(barriers),
      validateRestartProjection(taskSlots)
    else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
  }

  static func validateRestartProjection(_ slots: [EvaluationPageTaskSlot]) -> Bool {
    let pre = slots.filter { $0.stage == EvaluationPageStage.sealedPreRestart.rawValue }
    let post = slots.filter { $0.stage == EvaluationPageStage.sealedPostRestart.rawValue }
    let preBlocks = pre.enumerated().compactMap { index, slot in
      index.isMultiple(of: 2) ? "\(slot.fixtureID):\(slot.replicate):\(slot.blockOrderKey)" : nil
    }
    let postBlocks = post.map { "\($0.fixtureID):\($0.replicate):\($0.blockOrderKey)" }
    return preBlocks == postBlocks
  }
}

// MARK: - Task Stage Validation

private extension EvaluationPageRunOrder {
  static func taskStageExpectations(
    _ stage: EvaluationPageStage,
    counterbalancePhase: Int?
  ) throws -> EvaluationPageTaskStageExpectations {
    switch stage {
    case .development:
      guard counterbalancePhase == nil else {
        throw EvaluationPagePipelineError.invalidRunOrder
      }
      return EvaluationPageTaskStageExpectations(
        conditions: [EvaluationCondition.clean.runOrderValue],
        attemptCount: PageEvaluationContract.pageDevelopmentPlannedAttempts,
        fixtureCount: PageEvaluationContract.developmentFixtureCount
      )
    case .regression:
      guard counterbalancePhase != nil else {
        throw EvaluationPagePipelineError.invalidRunOrder
      }
      return EvaluationPageTaskStageExpectations(
        conditions: lessonConditionedConditions,
        attemptCount: PageEvaluationContract.pageRegressionPlannedAttempts,
        fixtureCount: PageEvaluationContract.regressionFixtureCount
      )
    case .sealedPreRestart:
      guard counterbalancePhase != nil else {
        throw EvaluationPagePipelineError.invalidRunOrder
      }
      return EvaluationPageTaskStageExpectations(
        conditions: lessonConditionedConditions,
        attemptCount: PageEvaluationContract.pageSealedPreRestartPlannedAttempts,
        fixtureCount: PageEvaluationContract.sealedFixtureCount
      )
    case .sealedPostRestart:
      guard counterbalancePhase == nil else {
        throw EvaluationPagePipelineError.invalidRunOrder
      }
      return EvaluationPageTaskStageExpectations(
        conditions: [EvaluationCondition.postRestartLessonConditioned.runOrderValue],
        attemptCount: PageEvaluationContract.pageSealedPostRestartPlannedAttempts,
        fixtureCount: PageEvaluationContract.sealedFixtureCount
      )
    case .canary, .synthesis:
      throw EvaluationPagePipelineError.invalidRunOrder
    }
  }

  static var lessonConditionedConditions: [String] {
    [
      EvaluationCondition.clean.runOrderValue,
      EvaluationCondition.lessonConditioned.runOrderValue,
    ]
  }

  static func validateTaskSlots(
    _ slots: [EvaluationPageTaskSlot],
    split: String,
    expectations: EvaluationPageTaskStageExpectations
  ) throws {
    guard
      slots.count == expectations.attemptCount,
      slots.map(\.orderIndex) == Array(0..<expectations.attemptCount),
      Set(slots.map(\.fixtureID)).count == expectations.fixtureCount,
      slots.allSatisfy({ validFixtureID($0.fixtureID, split: split) }),
      slots.allSatisfy({ (1...PageEvaluationContract.replicateCount).contains($0.replicate) }),
      slots.allSatisfy({ SHA256Digest.isCanonicalHex($0.orderKey) }),
      slots.allSatisfy({ SHA256Digest.isCanonicalHex($0.blockOrderKey) }),
      slots.allSatisfy({ SHA256Digest.isCanonicalHex($0.workerProcessKey) })
    else { throw EvaluationPagePipelineError.invalidRunOrder }
  }

  static func validateTaskBlocks(
    _ slots: [EvaluationPageTaskSlot],
    counterbalancePhase: Int?,
    expectations: EvaluationPageTaskStageExpectations
  ) throws {
    let blockSize = expectations.conditions.count
    var identities = Set<String>()
    for blockIndex in 0..<(expectations.attemptCount / blockSize) {
      let start = blockIndex * blockSize
      let block = Array(slots[start..<(start + blockSize)])
      guard
        block.allSatisfy({ $0.blockIndex == blockIndex }),
        Set(block.map(\.fixtureID)).count == 1,
        Set(block.map(\.replicate)).count == 1,
        Set(block.map(\.blockOrderKey)).count == 1,
        identities.insert("\(block[0].fixtureID):\(block[0].replicate)").inserted
      else { throw EvaluationPagePipelineError.invalidRunOrder }

      let conditions = counterbalancedConditions(
        expectations.conditions,
        blockIndex: blockIndex,
        phase: counterbalancePhase
      )
      guard
        block.map(\.condition) == conditions,
        block.map(\.lessonSource) == conditions.map(lessonSource)
      else {
        throw EvaluationPagePipelineError.invalidRunOrder
      }
    }
  }

  static func counterbalancedConditions(
    _ conditions: [String],
    blockIndex: Int,
    phase: Int?
  ) -> [String] {
    guard let phase, (blockIndex + phase).isMultiple(of: 2) == false else {
      return conditions
    }
    return conditions.reversed()
  }

  static func lessonSource(for condition: String) -> EvaluationLessonSource {
    switch EvaluationCondition(runOrderValue: condition) {
    case .lessonConditioned: .artifact
    case .postRestartLessonConditioned: .durableActive
    default: .clean
    }
  }

  static func validateTaskReplicates(_ slots: [EvaluationPageTaskSlot]) throws {
    let fixtures = Dictionary(grouping: slots, by: \.fixtureID)
    let expectedReplicates = Set(1...PageEvaluationContract.replicateCount)
    guard fixtures.values.allSatisfy({ Set($0.map(\.replicate)) == expectedReplicates }) else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
  }

  static func validFixtureID(_ value: String, split: String) -> Bool {
    let prefix = "pc-\(split)-"
    guard value.hasPrefix(prefix), value.count == prefix.count + 2 else { return false }
    return value.dropFirst(prefix.count).allSatisfy { "0123456789".contains($0) }
  }
}
