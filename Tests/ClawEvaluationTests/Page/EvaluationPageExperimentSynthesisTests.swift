import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationPageExperimentSynthesisTests {
  @Test func eligibleCredentialExhaustionUsesTheSingleSynthesisReplacement() async throws {
    // given — the policy test owns cause classification; this test proves synthesis consumes a
    // non-transport eligible result and emits the frozen coarse transport-failure outcome.
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeSynthesisControllerFixture(root: root)
    let original = try fixture.factory.makeSynthesisConfiguration(
      slot: fixture.slot,
      synthesisInputURL: fixture.paths.synthesisInput
    )
    let replacement = try fixture.factory.makeSynthesisConfiguration(
      slot: fixture.slot,
      synthesisInputURL: fixture.paths.synthesisInput,
      replacementOf: original.attemptID
    )
    let originalProcessUUID = try #require(
      UUID(uuidString: "11111111-1111-1111-1111-111111111111")
    )
    let replacementProcessUUID = try #require(
      UUID(uuidString: "22222222-2222-2222-2222-222222222222")
    )
    let credentialReason = try #require(
      EvaluationAttemptFailurePolicy.replacementReason(for: .credentialRefreshExhausted)
    )
    let candidate = #"{"lesson_set_id":"replacement","lessons":[],"schema_version":1}"#
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
      let configuration = try #require(configurations.first)
      let specification =
        configuration.replacementOrdinal == 0
        ? SynthesisResultSpecification(
          disposition: .eligible,
          replacementReason: credentialReason,
          rawOutput: nil,
          processUUID: originalProcessUUID
        )
        : SynthesisResultSpecification(
          disposition: .ineligible,
          replacementReason: nil,
          rawOutput: candidate,
          processUUID: replacementProcessUUID
        )
      try publishSynthesisResult(
        invocation: invocation,
        configuration: configuration,
        specification: specification
      )
      return EvaluationWorkerLaunchResult(termination: .completed, processID: 1)
    }
    let experiment = makeSynthesisExperiment(fixture: fixture, launcher: launcher)
    var page = EvaluationController.Accumulator()

    // when
    let execution = try await experiment.runSynthesis(
      factory: fixture.factory,
      slot: fixture.slot,
      executable: fixture.executable.path,
      inputs: fixture.inputs,
      freeze: fixture.context,
      journal: fixture.journal,
      page: &page,
      paths: fixture.paths
    )

    // then — restoring the transport-reason literal would terminate before these replacement
    // effects, while leaking the typed reason would fail the transcript assertion.
    #expect(execution.result.attemptID == replacement.attemptID)
    #expect(page.replacements == 1)
    #expect(execution.attempts.count == 2)
    let first = try #require(execution.attempts.first)
    let second = try #require(execution.attempts.last)
    #expect(first["attempt_id"] as? String == original.attemptID)
    #expect(first["process_uuid"] as? String == originalProcessUUID.uuidString.lowercased())
    #expect(
      first["conversation_id"] as? String
        == "\(originalProcessUUID.uuidString.lowercased()):\(original.attemptID)"
    )
    #expect(first["raw_output"] is NSNull)
    #expect(first["runtime_outcome"] as? String == "transport_failure")
    #expect(second["attempt_id"] as? String == replacement.attemptID)
    #expect(second["raw_output"] as? String == candidate)
    #expect(second["runtime_outcome"] as? String == "completed")
    #expect(
      try EvaluationPathSecurity.readRegularSingleLinkFile(at: fixture.paths.synthesisCandidate)
        == Data(candidate.utf8)
    )
  }

  @Test
  func interruptedSynthesisWithoutAResultUsesTheSingleReplacementAndRecordsNoOutput() async throws {
    // given — downstream validation accepts null transport identities; this test proves the Swift
    // producer records that row and consumes the process-interruption replacement.
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeSynthesisControllerFixture(root: root)
    let original = try fixture.factory.makeSynthesisConfiguration(
      slot: fixture.slot,
      synthesisInputURL: fixture.paths.synthesisInput
    )
    let replacement = try fixture.factory.makeSynthesisConfiguration(
      slot: fixture.slot,
      synthesisInputURL: fixture.paths.synthesisInput,
      replacementOf: original.attemptID
    )
    let replacementProcessUUID = try #require(
      UUID(uuidString: "33333333-3333-3333-3333-333333333333")
    )
    let candidate = #"{"lesson_set_id":"after-interruption","lessons":[],"schema_version":1}"#
    let launcher = ScriptedEvaluationWorkerLauncher { invocation, configurations, _ in
      let configuration = try #require(configurations.first)
      guard configuration.replacementOrdinal == 1 else {
        return EvaluationWorkerLaunchResult(termination: .interrupted, processID: 1)
      }
      try publishSynthesisResult(
        invocation: invocation,
        configuration: configuration,
        specification: SynthesisResultSpecification(
          disposition: .ineligible,
          replacementReason: nil,
          rawOutput: candidate,
          processUUID: replacementProcessUUID
        )
      )
      return EvaluationWorkerLaunchResult(termination: .completed, processID: 2)
    }
    let experiment = makeSynthesisExperiment(fixture: fixture, launcher: launcher)
    var page = EvaluationController.Accumulator()

    // when
    let execution = try await experiment.runSynthesis(
      factory: fixture.factory,
      slot: fixture.slot,
      executable: fixture.executable.path,
      inputs: fixture.inputs,
      freeze: fixture.context,
      journal: fixture.journal,
      page: &page,
      paths: fixture.paths
    )

    // then — retaining the missing-to-incomplete branch, omitting the original row, using the
    // replacement ID, or inventing runtime identities would fail these observable effects.
    #expect(execution.result.attemptID == replacement.attemptID)
    #expect(page.replacements == 1)
    #expect(execution.attempts.count == 2)
    let first = try #require(execution.attempts.first)
    let second = try #require(execution.attempts.last)
    #expect(first["attempt_id"] as? String == original.attemptID)
    #expect(first["process_uuid"] is NSNull)
    #expect(first["conversation_id"] is NSNull)
    #expect(first["raw_output"] is NSNull)
    #expect(first["runtime_outcome"] as? String == "transport_failure")
    #expect(second["attempt_id"] as? String == replacement.attemptID)
    #expect(second["raw_output"] as? String == candidate)
    #expect(second["runtime_outcome"] as? String == "completed")
    #expect(
      try EvaluationPathSecurity.readRegularSingleLinkFile(at: fixture.paths.synthesisCandidate)
        == Data(candidate.utf8)
    )
  }
}

private struct SynthesisControllerFixture {
  let inputs: EvaluationFreezeInputs
  let context: EvaluationFreezeContext
  let executable: URL
  let slot: EvaluationPageSynthesisSlot
  let paths: EvaluationController.PagePipelinePaths
  let factory: EvaluationPageConfigurationFactory
  let journal: EvaluationControllerJournal
}

private struct SynthesisResultSpecification: Sendable {
  let disposition: EvaluationReplacementDisposition
  let replacementReason: String?
  let rawOutput: String?
  let processUUID: UUID
}

private func makeSynthesisControllerFixture(root: URL) throws -> SynthesisControllerFixture {
  let base = try makeCanaryControllerFixture(root: root)
  let context = try makeSynthesisContext(base: base, root: root)
  let order = try EvaluationPageRunOrder.decode(
    context.runOrderJSON,
    approvedManifestSHA256: context.receipt.manifest.sha256
  )
  let input = try EvaluationCanonicalJSON.data(fromJSONObject: [
    "schema_version": 1,
    "selected_target_classes": ["noise.volatile_value", "noise.structure_or_order"],
  ])
  try EvaluationDurablePublication.publish(input, to: base.paths.synthesisInput)
  let factory = EvaluationPageConfigurationFactory(
    freeze: context,
    freezeInputs: base.inputs,
    catalog: EvaluationPageFixtureCatalog(fixtures: [], byID: [:]),
    configurationDirectory: base.paths.configurations,
    resultDirectory: base.paths.results
  )
  let journal = try EvaluationControllerJournal.startNew(
    evaluationRoot: context.runtime.evaluationRootURL,
    manifestSHA256: context.receipt.manifest.sha256,
    freezeCommit: context.receipt.freezeCommit,
    fixedTimestamp: context.runtime.fixedTimestamp,
    journalName: "synthesis-test.jsonl"
  )
  return SynthesisControllerFixture(
    inputs: base.inputs,
    context: context,
    executable: base.executable,
    slot: order.synthesis,
    paths: base.paths,
    factory: factory,
    journal: journal
  )
}

private func makeSynthesisContext(
  base: CanaryControllerFixture,
  root: URL
) throws -> EvaluationFreezeContext {
  let promptPath = "prompts/synthesis.md"
  let promptURL = root.appendingPathComponent(promptPath)
  let prompt = Data("Synthesize one lesson set from synthesis-input.json.".utf8)
  try FileManager.default.createDirectory(
    at: promptURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try prompt.write(to: promptURL)
  let artifact = EvaluationManifestArtifact(
    role: "synthesis",
    path: promptPath,
    bytes: prompt.count,
    sha256: SHA256Digest.hex(prompt)
  )
  var categories = base.context.manifest.categories
  let prompts = try #require(categories["prompts"])
  categories["prompts"] = EvaluationManifestCategory(
    artifacts: prompts.artifacts + [artifact],
    values: prompts.values,
    sha256: prompts.sha256
  )
  let manifest = EvaluationFreezeManifest(
    schemaVersion: base.context.manifest.schemaVersion,
    decision: base.context.manifest.decision,
    experiment: base.context.manifest.experiment,
    protocolBinding: base.context.manifest.protocolBinding,
    categories: categories,
    protectedArtifacts: base.context.manifest.protectedArtifacts + [
      EvaluationManifestProtectedArtifact(
        path: artifact.path,
        bytes: artifact.bytes,
        sha256: artifact.sha256
      )
    ]
  )
  return EvaluationFreezeContext(
    repositoryRoot: base.context.repositoryRoot,
    manifest: manifest,
    receipt: base.context.receipt,
    runtime: base.context.runtime,
    runOrderJSON: base.context.runOrderJSON
  )
}

private func makeSynthesisExperiment(
  fixture: SynthesisControllerFixture,
  launcher: ScriptedEvaluationWorkerLauncher
) -> EvaluationPageExperiment {
  EvaluationPageExperiment(
    freezeVerifier: StaticEvaluationFreezeVerifier(context: fixture.context),
    artifacts: StaticEvaluationProtectedArtifactRunner(output: Data()),
    launcher: launcher
  )
}

private func publishSynthesisResult(
  invocation: EvaluationWorkerInvocation,
  configuration: EvaluationAttemptConfiguration,
  specification: SynthesisResultSpecification
) throws {
  let result = makeEvaluationResult(
    configuration: configuration,
    replacementDisposition: specification.disposition,
    replacementReason: specification.replacementReason,
    rawOutput: specification.rawOutput,
    processUUID: specification.processUUID
  )
  try EvaluationJSONFile.write(result, to: configuration.resultURL)
  try publishEvaluationAttemptProgress(
    invocation: invocation,
    configurations: [configuration],
    results: [result]
  )
}
