import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationPagePipelineTests {
  @Test func rejectedLessonSynthesisPublishesOneClosedRejectionReport() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = try makeEvaluationConfiguration(root: root, attemptID: "synthesis-base")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [base.configuration])
    let paths = EvaluationController.PagePipelinePaths(
      evaluationRoot: base.configuration.evaluationRootURL
    )
    let synthesisInput = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "selected_target_classes": ["noise.volatile_value"],
      "schema_version": 1,
    ])
    let synthesisPrompt = Data("Produce one bounded lesson set.".utf8)
    let synthesisPromptURL = root.appendingPathComponent("artifacts/synthesis.md")
    try synthesisPrompt.write(to: synthesisPromptURL)
    var categories = frozen.context.manifest.categories
    let synthesisPromptRecord = EvaluationManifestArtifact(
      role: "synthesis",
      path: "artifacts/synthesis.md",
      bytes: synthesisPrompt.count,
      sha256: SHA256Digest.hex(synthesisPrompt)
    )
    categories["prompts"] = EvaluationManifestCategory(
      artifacts: (categories["prompts"]?.artifacts ?? []) + [synthesisPromptRecord],
      sha256: categories["prompts"]?.sha256 ?? String(repeating: "a", count: 64)
    )
    categories["feedback"] = EvaluationManifestCategory(
      artifacts: [],
      sha256: String(repeating: "e", count: 64)
    )
    let manifest = EvaluationFreezeManifest(
      schemaVersion: frozen.context.manifest.schemaVersion,
      decision: frozen.context.manifest.decision,
      experiment: frozen.context.manifest.experiment,
      protocolBinding: frozen.context.manifest.protocolBinding,
      categories: categories,
      protectedArtifacts: frozen.context.manifest.protectedArtifacts + [
        EvaluationManifestProtectedArtifact(
          path: synthesisPromptRecord.path,
          bytes: synthesisPromptRecord.bytes,
          sha256: synthesisPromptRecord.sha256
        )
      ]
    )
    let context = EvaluationFreezeContext(
      repositoryRoot: frozen.context.repositoryRoot,
      manifest: manifest,
      receipt: frozen.context.receipt,
      runtime: frozen.context.runtime,
      runOrderJSON: frozen.context.runOrderJSON
    )
    let clean = try EvaluationPageLessonBinding.clean()
    let configuration = EvaluationAttemptConfiguration(
      attemptID: "page-synthesis-test",
      fixtureID: "pc-synthesis-01",
      taskID: "page-000000000001",
      split: "development",
      stage: "synthesis",
      frozenOrderIndex: 0,
      frozenOrderKey: String(repeating: "d", count: 64),
      replicate: 1,
      condition: .synthesis,
      evaluationRoot: base.configuration.evaluationRoot,
      sourceArtifactPath: paths.synthesisInput.path,
      sourceSHA256: SHA256Digest.hex(synthesisInput),
      inputSHA256: SHA256Digest.hex(synthesisInput),
      lessonSource: .clean,
      taskPromptPath: synthesisPromptURL.path,
      taskPromptSHA256: synthesisPromptRecord.sha256,
      resultPath: paths.results.appendingPathComponent("page-synthesis-test.json").path,
      fixedTimestamp: base.configuration.fixedTimestamp,
      protocolSHA256: base.configuration.protocolSHA256,
      lessonSetDigest: clean.digest,
      expectedPolicyVersion: base.configuration.expectedPolicyVersion,
      approval: base.configuration.approval,
      provenance: base.configuration.provenance
    )
    let result = makeEvaluationResult(
      configuration: configuration,
      replacementDisposition: .ineligible
    )
    let lint = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "accepted": false,
      "errors": [["code": "lesson.too_specific"]],
      "schema_version": 1,
    ])
    let launcher = ScriptedEvaluationWorkerLauncher { _, _, _ in
      EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
    let experiment = EvaluationPageExperiment(
      freezeVerifier: StaticEvaluationFreezeVerifier(context: context),
      artifacts: StaticEvaluationProtectedArtifactRunner(output: lint),
      launcher: launcher
    )
    try experiment.prepare(paths)
    try EvaluationDurablePublication.publish(synthesisInput, to: paths.synthesisInput)
    try EvaluationDurablePublication.publish(
      Data(#"{"schema_version":1}"#.utf8),
      to: paths.synthesisCandidate
    )
    let execution = EvaluationSynthesisExecution(
      result: result,
      attempts: [
        [
          "attempt_id": result.attemptID,
          "attempt_index": 1,
          "conversation_id": result.conversationID,
          "process_uuid": result.processUUID.uuidString.lowercased(),
          "raw_output": result.rawOutput ?? NSNull(),
          "runtime_outcome": "completed",
        ]
      ]
    )

    // when
    let outcome = try await experiment.promote(
      synthesis: execution,
      freeze: context,
      paths: paths
    )

    // then — no rewrite or second synthesis is possible; all rejection provenance is immutable.
    #expect(outcome == .rejected)
    #expect(FileManager.default.fileExists(atPath: paths.promotedTemporary.path) == false)
    #expect(FileManager.default.fileExists(atPath: paths.promotionReceipt.path) == false)
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: paths.synthesisRejectionReport))
        as? [String: Any]
    )
    #expect(report["outcome"] as? String == "page_task_specific_failure")
    #expect(report["rejection_codes"] as? [String] == ["lesson.too_specific"])
    #expect(
      report["synthesis_transcript_sha256"] as? String
        == SHA256Digest.hex(try Data(contentsOf: paths.synthesisTranscript))
    )
    #expect(await launcher.observations.isEmpty)
  }

  @Test func synthesisInputInvocationCarriesTheManifestBoundFeedbackGeneratorDigest() async throws {
    // given — synthesis.py requires the digest as an explicit provenance input; the feedback
    // category is the approved source rather than a caller-supplied duplicate.
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = try makeEvaluationConfiguration(root: root, attemptID: "synthesis-input-contract")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [base.configuration])
    let relativeInputs = [
      "\(EvaluationController.pageRootPath)/contracts/error-codes.json",
      "\(EvaluationController.pageRootPath)/contracts/feedback-templates.json",
      "\(EvaluationController.pageRootPath)/schemas/lesson-set.schema.json",
      "\(EvaluationController.pageRootPath)/contracts/lesson-lint-rules.json",
    ]
    let protectedInputs = try relativeInputs.map { relative in
      let url = root.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = Data(#"{"schema_version":1}"#.utf8)
      try data.write(to: url)
      return EvaluationManifestProtectedArtifact(
        path: relative,
        bytes: data.count,
        sha256: SHA256Digest.hex(data)
      )
    }
    let feedbackGeneratorSHA256 = String(repeating: "e", count: 64)
    var categories = frozen.context.manifest.categories
    categories["feedback"] = EvaluationManifestCategory(
      artifacts: [],
      sha256: feedbackGeneratorSHA256
    )
    let context = EvaluationFreezeContext(
      repositoryRoot: frozen.context.repositoryRoot,
      manifest: EvaluationFreezeManifest(
        schemaVersion: frozen.context.manifest.schemaVersion,
        decision: frozen.context.manifest.decision,
        experiment: frozen.context.manifest.experiment,
        protocolBinding: frozen.context.manifest.protocolBinding,
        categories: categories,
        protectedArtifacts: frozen.context.manifest.protectedArtifacts + protectedInputs
      ),
      receipt: frozen.context.receipt,
      runtime: frozen.context.runtime,
      runOrderJSON: frozen.context.runOrderJSON
    )
    let output = try EvaluationCanonicalJSON.data(fromJSONObject: ["schema_version": 1])
    let runner = ScriptedEvaluationProtectedArtifactRunner(output: output)
    let launcher = ScriptedEvaluationWorkerLauncher { _, _, _ in
      EvaluationWorkerLaunchResult(termination: .rejected, processID: nil)
    }
    let experiment = EvaluationPageExperiment(
      freezeVerifier: StaticEvaluationFreezeVerifier(context: context),
      artifacts: runner,
      launcher: launcher
    )
    let paths = EvaluationController.PagePipelinePaths(
      evaluationRoot: base.configuration.evaluationRootURL
    )
    try experiment.prepare(paths)

    // when
    try await experiment.buildSynthesisInput(freeze: context, paths: paths)

    // then — mutant: omitting the required flag (or sourcing another digest) cannot launch the
    // production CLI contract while this assertion still passes.
    let invocations = await runner.invocations
    #expect(invocations.count == 1)
    let invocation = try #require(invocations.first)
    let flagIndex = try #require(
      invocation.arguments.firstIndex(of: "--feedback-generator-sha256")
    )
    #expect(invocation.arguments.index(after: flagIndex) < invocation.arguments.endIndex)
    #expect(invocation.arguments[flagIndex + 1] == feedbackGeneratorSHA256)
    #expect(await launcher.observations.isEmpty)
  }

  @Test func pageRecordPreservesNullableFailedToolSafetyAndUsesAnAbsoluteManifestPath()
    async throws
  {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root, attemptID: "record-safety")
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configured.configuration])
    let workspace = try EvaluationWorkspaceMaterializer.reset(
      configuration: configured.configuration
    )
    let result = makeEvaluationResult(
      configuration: configured.configuration,
      replacementDisposition: .ineligible,
      workspace: workspace,
      tools: [
        EvaluationToolRecord(
          name: "web_fetch",
          path: nil,
          status: EvaluationToolContract.failedStatus
        ),
        EvaluationToolRecord(
          name: EvaluationToolContract.requiredToolName,
          path: nil,
          status: EvaluationToolContract.failedStatus
        ),
      ]
    )
    let sourceRelativePath = try #require(
      frozen.context.manifest.protectedArtifacts.first {
        $0.sha256 == configured.configuration.sourceSHA256
      }?.path
    )
    let fixture = EvaluationPageFixture(
      fixtureID: configured.configuration.fixtureID,
      split: configured.configuration.split,
      sourceRelativePath: sourceRelativePath,
      goldRelativePath: sourceRelativePath,
      taskID: configured.configuration.taskID,
      sourceSHA256: configured.configuration.sourceSHA256
    )
    let slot = EvaluationPageTaskSlot(
      stage: configured.configuration.stage,
      split: configured.configuration.split,
      orderIndex: configured.configuration.frozenOrderIndex,
      blockIndex: 0,
      orderKey: configured.configuration.frozenOrderKey,
      blockOrderKey: String(repeating: "b", count: 64),
      fixtureID: configured.configuration.fixtureID,
      replicate: configured.configuration.replicate,
      condition: configured.configuration.condition.runOrderValue,
      lessonSource: configured.configuration.lessonSource,
      workerProcessKey: String(repeating: "e", count: 64)
    )
    let recordData = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "attempt_id": result.attemptID,
      "carrier_receipt_sha256": result.carrierReceiptSHA256,
    ])
    let runner = ScriptedEvaluationProtectedArtifactRunner(output: recordData)

    // when
    _ = try await EvaluationPageRecordBuilder(artifacts: runner).writeBundle(
      attempts: [
        EvaluationRecordedAttempt(
          result: result,
          resultOrEnvelopeSHA256: String(repeating: "f", count: 64)
        )
      ],
      runOrder: EvaluationPageRunOrder(
        canaryProcesses: [],
        taskSlots: [slot],
        synthesis: EvaluationPageSynthesisSlot(
          orderKey: SHA256Digest.hex("unused-synthesis"),
          workerProcessKey: SHA256Digest.hex("unused-synthesis-worker"),
          promptPath: "unused"
        )
      ),
      catalog: EvaluationPageFixtureCatalog(
        fixtures: [fixture],
        byID: [fixture.fixtureID: fixture]
      ),
      freeze: frozen.context,
      lifecycleReceiptSHA256: "",
      outputURL: root.appendingPathComponent("records.json")
    )

    // then — rejecting a missing path on either a failed required read or an unknown tool erases
    // scorer-owned safety; a relative manifest argument makes page-record depend on the CWD.
    let invocation = try #require(await runner.invocations.first)
    let attemptFlag = try #require(invocation.arguments.firstIndex(of: "--attempt"))
    let attemptData = try EvaluationPathSecurity.readRegularSingleLinkFile(
      at: URL(fileURLWithPath: invocation.arguments[attemptFlag + 1])
    )
    let attemptObject = try #require(
      JSONSerialization.jsonObject(with: attemptData) as? [String: Any]
    )
    let toolEvents = try #require(attemptObject["tool_events"] as? [[String: Any]])
    #expect(toolEvents.count == 2)
    #expect(toolEvents[0]["name"] as? String == "web_fetch")
    #expect(toolEvents[0]["path"] is NSNull)
    #expect(toolEvents[1]["name"] as? String == EvaluationToolContract.requiredToolName)
    #expect(toolEvents[1]["path"] is NSNull)
    let manifestFlag = try #require(invocation.arguments.firstIndex(of: "--manifest"))
    #expect(
      invocation.arguments[manifestFlag + 1]
        == root.appendingPathComponent("config/manifest.json").standardizedFileURL.path
    )
    #expect(invocation.arguments[manifestFlag + 1].hasPrefix("/"))
  }
}
