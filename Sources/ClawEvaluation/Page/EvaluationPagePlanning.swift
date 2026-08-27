import ClawAgent
import ClawCore
import Foundation

struct EvaluationPageFixture: Sendable, Equatable {
  let fixtureID: String
  let split: String
  let sourceRelativePath: String
  let goldRelativePath: String
  let taskID: String
  let sourceSHA256: String
}

struct EvaluationPageFixtureCatalog: Sendable {
  let fixtures: [EvaluationPageFixture]
  let byID: [String: EvaluationPageFixture]

  static func load(freeze: EvaluationFreezeContext) throws -> Self {
    guard let splits = freeze.manifest.artifact(role: "splits", category: "splits") else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }
    let repository = URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
    let splitData = try EvaluationManifestBoundArtifactReader.read(
      splits,
      repositoryRoot: repository
    ).data
    guard
      let root = try JSONSerialization.jsonObject(with: splitData) as? [String: Any],
      let splitObject = root["splits"] as? [String: [[String: Any]]]
    else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }
    var entries: [String: EvaluationPageFixture] = [:]
    var ordered: [EvaluationPageFixture] = []
    for (split, fixtures) in splitObject {
      for fixture in fixtures {
        guard
          let fixtureID = fixture["fixture_id"] as? String,
          let familyID = fixture["family_id"] as? String,
          let sourceSuffix = fixture["source"] as? String,
          let goldSuffix = fixture["gold"] as? String
        else {
          throw EvaluationPagePipelineError.invalidManifestContract
        }
        let sourceRelative = "\(EvaluationController.pageRootPath)/\(sourceSuffix)"
        let goldRelative = "\(EvaluationController.pageRootPath)/\(goldSuffix)"
        guard
          let sourceArtifact = freeze.manifest.artifact(relativePath: sourceRelative),
          freeze.manifest.artifact(relativePath: goldRelative) != nil
        else {
          throw EvaluationPagePipelineError.invalidManifestContract
        }
        let sourceData = try EvaluationManifestBoundArtifactReader.read(
          sourceArtifact,
          repositoryRoot: repository
        ).data
        guard
          let source = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
          source["fixture_id"] as? String == fixtureID,
          source["family_id"] as? String == familyID,
          source["split"] as? String == split,
          let taskID = source["task_id"] as? String,
          entries[fixtureID] == nil
        else {
          throw EvaluationPagePipelineError.invalidManifestContract
        }
        let entry = EvaluationPageFixture(
          fixtureID: fixtureID,
          split: split,
          sourceRelativePath: sourceRelative,
          goldRelativePath: goldRelative,
          taskID: taskID,
          sourceSHA256: sourceArtifact.sha256
        )
        entries[fixtureID] = entry
        ordered.append(entry)
      }
    }
    guard entries.count == PageEvaluationContract.fixtureCount else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }
    return Self(fixtures: ordered.sorted { $0.fixtureID < $1.fixtureID }, byID: entries)
  }
}

struct EvaluationPageLessonBinding: Sendable {
  let source: EvaluationLessonSource
  let artifactURL: URL?
  let data: Data
  let digest: String
  let promotionReceiptURL: URL?
  let promotionReceiptSHA256: String?

  static func clean() throws -> Self {
    let data = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "lesson_set_id": "empty", "lessons": [], "schema_version": 1,
    ])
    return Self(
      source: .clean,
      artifactURL: nil,
      data: data,
      digest: SHA256Digest.hex(data),
      promotionReceiptURL: nil,
      promotionReceiptSHA256: nil
    )
  }

  static func promoted(
    source: EvaluationLessonSource,
    artifactURL: URL,
    promotionReceiptURL: URL,
    promotionReceiptSHA256: String
  ) throws -> Self {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: artifactURL)
    return Self(
      source: source,
      artifactURL: source == .artifact ? artifactURL : nil,
      data: data,
      digest: SHA256Digest.hex(data),
      promotionReceiptURL: promotionReceiptURL,
      promotionReceiptSHA256: promotionReceiptSHA256
    )
  }
}

struct EvaluationPageConfigurationFactory {
  let freeze: EvaluationFreezeContext
  let freezeInputs: EvaluationFreezeInputs
  let catalog: EvaluationPageFixtureCatalog
  let configurationDirectory: URL
  let resultDirectory: URL

  func makeBlocks(
    slots: [EvaluationPageTaskSlot],
    lesson: EvaluationPageLessonBinding,
    publishOrderKey: String? = nil
  ) throws -> [EvaluationReplicateBlock] {
    var blocks: [EvaluationReplicateBlock] = []
    for slot in slots {
      let original = try configuration(
        for: slot,
        lesson: slot.lessonSource == .clean ? .clean() : lesson,
        publish: slot.orderKey == publishOrderKey,
        replacementOf: nil
      )
      let replacement = try configuration(
        for: slot,
        lesson: slot.lessonSource == .clean ? .clean() : lesson,
        publish: slot.orderKey == publishOrderKey,
        replacementOf: original.attemptID
      )
      let originalURL = configurationDirectory.appendingPathComponent("\(original.attemptID).json")
      let replacementURL = configurationDirectory.appendingPathComponent(
        "\(replacement.attemptID).json"
      )
      try EvaluationJSONFile.write(original, to: originalURL)
      try EvaluationJSONFile.write(replacement, to: replacementURL)
      let planned = EvaluationPlannedAttempt(
        configurationPath: originalURL.path,
        replacementConfigurationPath: replacementURL.path
      )
      if blocks.last?.blockID == slot.blockOrderKey {
        let prior = blocks.removeLast()
        blocks.append(
          EvaluationReplicateBlock(blockID: prior.blockID, attempts: prior.attempts + [planned])
        )
      } else {
        blocks.append(EvaluationReplicateBlock(blockID: slot.blockOrderKey, attempts: [planned]))
      }
    }
    return blocks
  }

  func makeSynthesisConfiguration(
    slot: EvaluationPageSynthesisSlot,
    synthesisInputURL: URL,
    replacementOf: String? = nil
  ) throws -> EvaluationAttemptConfiguration {
    let sourceData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: synthesisInputURL)
    let clean = try EvaluationPageLessonBinding.clean()
    let prompt = try artifact(role: "synthesis", category: "prompts")
    guard prompt.record.path == slot.promptPath else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    let baseID = "page-synthesis-\(slot.orderKey.prefix(16))"
    let attemptID = replacementOf == nil ? baseID : "\(baseID)-r1"
    return EvaluationAttemptConfiguration(
      attemptID: attemptID,
      fixtureID: "pc-synthesis-01",
      taskID: "page-\(slot.orderKey.prefix(12))",
      split: EvaluationPageSplit.development.rawValue,
      stage: EvaluationPageStage.synthesis.rawValue,
      frozenOrderIndex: 0,
      frozenOrderKey: slot.orderKey,
      replicate: 1,
      condition: .synthesis,
      evaluationRoot: freeze.runtime.evaluationRoot,
      sourceArtifactPath: synthesisInputURL.path,
      sourceSHA256: SHA256Digest.hex(sourceData),
      inputSHA256: SHA256Digest.hex(sourceData),
      lessonSource: .clean,
      taskPromptPath: prompt.url.path,
      taskPromptSHA256: prompt.record.sha256,
      resultPath: resultDirectory.appendingPathComponent("\(attemptID).json").path,
      fixedTimestamp: freeze.runtime.fixedTimestamp,
      protocolSHA256: try protocolSHA256(),
      lessonSetDigest: clean.digest,
      expectedPolicyVersion: freeze.runtime.expectedPolicyVersion,
      approval: try approval(),
      provenance: try provenance(),
      replacementOfAttemptID: replacementOf,
      replacementOrdinal: replacementOf == nil ? 0 : 1
    )
  }

  func makeCanaryConfigurations(
    process: EvaluationPageCanaryProcessSlot
  ) throws -> [EvaluationAttemptConfiguration] {
    let repository = URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
    let prompt = try artifact(role: "task", category: "prompts")
    return try process.attempts.map { slot in
      guard
        let sourceRecord = freeze.manifest.artifact(relativePath: slot.sourcePath),
        let contractRecord = freeze.manifest.artifact(relativePath: slot.configurationPath)
      else { throw EvaluationPagePipelineError.invalidManifestContract }
      let source = try EvaluationManifestBoundArtifactReader.read(
        sourceRecord,
        repositoryRoot: repository
      )
      let sourceURL = source.url
      let sourceData = source.data
      let contractData = try EvaluationManifestBoundArtifactReader.read(
        contractRecord,
        repositoryRoot: repository
      ).data
      guard
        let source = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
        source["fixture_id"] as? String == slot.fixtureID,
        source["task_id"] as? String == slot.taskID,
        let task = source["task"] as? [String: Any],
        let contract = try JSONSerialization.jsonObject(with: contractData) as? [String: Any],
        contract["fixture_id"] as? String == slot.fixtureID,
        contract["task_id"] as? String == slot.taskID,
        let expectedInputs = contract["expected_input_sha256"] as? [String: String]
      else { throw EvaluationPagePipelineError.invalidManifestContract }

      let lessonData: Data
      let lessonURL: URL?
      if let relative = slot.lessonArtifactPath {
        guard let record = freeze.manifest.artifact(relativePath: relative) else {
          throw EvaluationPagePipelineError.invalidManifestContract
        }
        let artifact = try EvaluationManifestBoundArtifactReader.read(
          record,
          repositoryRoot: repository
        )
        lessonData = artifact.data
        lessonURL = slot.lessonSource == .artifact ? artifact.url : nil
      } else {
        guard
          slot.lessonSource == .durableActive,
          let record = freeze.manifest.artifact(
            role: "canary_nonempty_lessons",
            category: "configuration"
          )
        else { throw EvaluationPagePipelineError.invalidManifestContract }
        lessonData = try EvaluationManifestBoundArtifactReader.read(
          record,
          repositoryRoot: repository
        ).data
        lessonURL = nil
      }
      let lessonObject = try JSONSerialization.jsonObject(with: lessonData)
      let input = try EvaluationCanonicalJSON.data(fromJSONObject: [
        "active_lessons": lessonObject,
        "schema_version": 1,
        "task": task,
        "task_id": slot.taskID,
      ])
      let expectedKey = slot.lessonSource == .clean ? "clean" : "nonempty"
      guard expectedInputs[expectedKey] == SHA256Digest.hex(input) else {
        throw EvaluationPagePipelineError.invalidManifestContract
      }
      let attemptID = "page-canary-\(process.process.lowercased())-\(slot.condition)"
      return EvaluationAttemptConfiguration(
        attemptID: attemptID,
        fixtureID: slot.fixtureID,
        taskID: slot.taskID,
        split: EvaluationPageSplit.development.rawValue,
        stage: EvaluationPageStage.canary.rawValue,
        frozenOrderIndex: slot.attemptIndex - 1,
        frozenOrderKey: slot.orderKey,
        replicate: 1,
        condition: .canary,
        evaluationRoot: freeze.runtime.evaluationRoot,
        sourceArtifactPath: sourceURL.path,
        sourceSHA256: sourceRecord.sha256,
        inputSHA256: SHA256Digest.hex(input),
        lessonSource: slot.lessonSource,
        lessonArtifactPath: lessonURL?.path,
        publishLessonAsActive: slot.publishActive,
        taskPromptPath: prompt.url.path,
        taskPromptSHA256: prompt.record.sha256,
        resultPath: resultDirectory.appendingPathComponent("\(attemptID).json").path,
        fixedTimestamp: freeze.runtime.fixedTimestamp,
        protocolSHA256: try protocolSHA256(),
        lessonSetDigest: SHA256Digest.hex(lessonData),
        expectedPolicyVersion: freeze.runtime.expectedPolicyVersion,
        approval: try approval(),
        provenance: try provenance()
      )
    }
  }

  private func configuration(
    for slot: EvaluationPageTaskSlot,
    lesson: EvaluationPageLessonBinding,
    publish: Bool,
    replacementOf: String?
  ) throws -> EvaluationAttemptConfiguration {
    guard let fixture = catalog.byID[slot.fixtureID] else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }
    let repository = URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
    guard let sourceRecord = freeze.manifest.artifact(relativePath: fixture.sourceRelativePath)
    else { throw EvaluationPagePipelineError.invalidManifestContract }
    let sourceArtifact = try EvaluationManifestBoundArtifactReader.read(
      sourceRecord,
      repositoryRoot: repository
    )
    let sourceURL = sourceArtifact.url
    let sourceData = sourceArtifact.data
    let lessonObject = try JSONSerialization.jsonObject(with: lesson.data)
    guard
      let sourceObject = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
      let task = sourceObject["task"] as? [String: Any]
    else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }
    let input = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "active_lessons": lessonObject,
      "schema_version": 1,
      "task": task,
      "task_id": fixture.taskID,
    ])
    guard let condition = EvaluationCondition(runOrderValue: slot.condition) else {
      throw EvaluationPagePipelineError.invalidRunOrder
    }
    let baseID = "page-\(slot.stage)-\(slot.orderKey.prefix(16))"
    let attemptID = replacementOf == nil ? baseID : "\(baseID)-r1"
    let prompt = try artifact(role: "task", category: "prompts")
    return EvaluationAttemptConfiguration(
      attemptID: attemptID,
      fixtureID: fixture.fixtureID,
      taskID: fixture.taskID,
      split: slot.split,
      stage: slot.stage,
      frozenOrderIndex: slot.orderIndex,
      frozenOrderKey: slot.orderKey,
      replicate: slot.replicate,
      condition: condition,
      evaluationRoot: freeze.runtime.evaluationRoot,
      sourceArtifactPath: sourceURL.path,
      sourceSHA256: fixture.sourceSHA256,
      inputSHA256: SHA256Digest.hex(input),
      lessonSource: lesson.source,
      lessonArtifactPath: lesson.artifactURL?.path,
      promotionReceiptPath: lesson.promotionReceiptURL?.path,
      promotionReceiptSHA256: lesson.promotionReceiptSHA256,
      publishLessonAsActive: publish,
      taskPromptPath: prompt.url.path,
      taskPromptSHA256: prompt.record.sha256,
      resultPath: resultDirectory.appendingPathComponent("\(attemptID).json").path,
      fixedTimestamp: freeze.runtime.fixedTimestamp,
      protocolSHA256: try protocolSHA256(),
      lessonSetDigest: lesson.digest,
      expectedPolicyVersion: freeze.runtime.expectedPolicyVersion,
      approval: try approval(),
      provenance: try provenance(),
      replacementOfAttemptID: replacementOf,
      replacementOrdinal: replacementOf == nil ? 0 : 1
    )
  }

  private func artifact(
    role: String,
    category: String
  ) throws -> (record: EvaluationManifestArtifact, url: URL) {
    guard let record = freeze.manifest.artifact(role: role, category: category) else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }
    let artifact = try EvaluationManifestBoundArtifactReader.read(
      record,
      repositoryRoot: URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
    )
    return (record, artifact.url)
  }

  private func protocolSHA256() throws -> String {
    guard let protocolBinding = freeze.manifest.protocolBinding else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }
    return protocolBinding.sha256
  }

  private func provenance() throws -> EvaluationFrozenProvenance {
    func digest(_ name: String) throws -> String {
      guard let value = freeze.manifest.categories[name]?.sha256 else {
        throw EvaluationPagePipelineError.invalidManifestContract
      }
      return value
    }
    return EvaluationFrozenProvenance(
      freezeCommit: freeze.receipt.freezeCommit,
      executableSHA256: freeze.receipt.executable.sha256,
      runtimeSourcesSHA256: try digest("runtime_sources"),
      harnessSourcesSHA256: try digest("harness_sources"),
      dependenciesSHA256: try digest("dependencies"),
      configurationSHA256: try digest("configuration"),
      modelSHA256: try digest("model"),
      retrySHA256: try digest("retry"),
      outputSHA256: try digest("output"),
      promptsSHA256: try digest("prompts"),
      schemasSHA256: try digest("schemas"),
      scorerSHA256: try digest("scorer"),
      splitsSHA256: try digest("splits"),
      runOrderSHA256: try digest("run_order"),
      systemPromptSHA256: SHA256Digest.hex(Data(SystemPrompt.minimal.utf8)),
      proactiveSystemPromptSHA256: SHA256Digest.hex(Data(SystemPrompt.proactive.utf8))
    )
  }

  private func approval() throws -> EvaluationApprovalBinding {
    let record = try EvaluationJSONFile.decode(
      ApprovalRecord.self,
      from: URL(fileURLWithPath: freezeInputs.approvalRecordPath)
    )
    return EvaluationApprovalBinding(
      commentID: freeze.receipt.comment.id,
      commentNodeID: freeze.receipt.comment.nodeID,
      authorLogin: freeze.receipt.comment.author.login,
      authorID: freeze.receipt.comment.author.id,
      authorNodeID: freeze.receipt.comment.author.nodeID,
      createdAt: freeze.receipt.comment.createdAt,
      updatedAt: freeze.receipt.comment.updatedAt,
      manifestSHA256: freeze.receipt.manifest.sha256,
      approvedManifestSHA256: freeze.receipt.manifest.sha256,
      approvalCommentURL: record.comment.htmlURL,
      approvalBodySHA256: freeze.receipt.comment.bodySHA256
    )
  }

  private struct ApprovalRecord: Decodable {
    struct Comment: Decodable {
      let htmlURL: String
      enum CodingKeys: String, CodingKey { case htmlURL = "html_url" }
    }
    let comment: Comment
  }
}
