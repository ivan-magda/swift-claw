import ClawCore
import Foundation

struct EvaluationRecordedAttempt: Sendable {
  let result: EvaluationAttemptResult
  let resultOrEnvelopeSHA256: String
  let originalAttemptEvidenceSHA256: String?

  init(
    result: EvaluationAttemptResult,
    resultOrEnvelopeSHA256: String,
    originalAttemptEvidenceSHA256: String? = nil
  ) {
    self.result = result
    self.resultOrEnvelopeSHA256 = resultOrEnvelopeSHA256
    self.originalAttemptEvidenceSHA256 = originalAttemptEvidenceSHA256
  }
}

struct EvaluationPageRecordBuilder: Sendable {
  let artifacts: any EvaluationProtectedArtifactRunning

  private static let pageRecordExecutablePath =
    "\(EvaluationController.pageRootPath)/artifacts/page-record"

  // swiftlint:disable:next function_body_length function_parameter_count
  func writeBundle(
    attempts: [EvaluationRecordedAttempt],
    runOrder: EvaluationPageRunOrder,
    catalog: EvaluationPageFixtureCatalog,
    freeze: EvaluationFreezeContext,
    lifecycleReceiptSHA256: String,
    outputURL: URL
  ) async throws -> [[String: Any]] {
    let manifestURL = try EvaluationManifestBoundArtifactReader.resolve(
      relativePath: freeze.receipt.manifest.path,
      repositoryRoot: URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
    )
    let scratch = try privatePublicationDirectory(for: outputURL)

    var records: [[String: Any]] = []
    var recordURLs: [URL] = []
    for attempt in attempts {
      let result = attempt.result
      guard
        let slot = runOrder.taskSlots.first(where: { $0.orderKey == result.frozenOrderKey }),
        let fixture = catalog.byID[result.fixtureID],
        let lockAcquisitionID = result.lockAcquisitionID,
        slot.fixtureID == result.fixtureID
      else {
        throw EvaluationPagePipelineError.recordConstructionFailed(result.attemptID)
      }

      let attemptURL = scratch.appendingPathComponent("\(result.attemptID)-attempt.json")
      let carrierURL = scratch.appendingPathComponent("\(result.attemptID)-carrier.json")
      let skeletonURL = scratch.appendingPathComponent("\(result.attemptID)-skeleton.json")
      let recordURL = scratch.appendingPathComponent("\(result.attemptID)-record.json")

      let replacedAttempt: Any = result.replacementOfAttemptID.map { $0 as Any } ?? NSNull()
      let originalEvidence: Any =
        attempt.originalAttemptEvidenceSHA256.map { $0 as Any } ?? NSNull()

      guard
        (result.replacementOrdinal == 0
          && result.replacementOfAttemptID == nil
          && attempt.originalAttemptEvidenceSHA256 == nil)
          || (result.replacementOrdinal == 1
            && result.replacementOfAttemptID != nil
            && attempt.originalAttemptEvidenceSHA256.map { SHA256Digest.isCanonicalHex($0) }
              == true)
      else {
        throw EvaluationPagePipelineError.recordConstructionFailed(result.attemptID)
      }

      try writeAttempt(result, to: attemptURL)
      let carrierPublication = try EvaluationFrozenArtifactPublication(
        encoding: result.carrierReceipt
      )

      guard carrierPublication.sha256 == result.carrierReceiptSHA256 else {
        throw EvaluationPagePipelineError.recordConstructionFailed(result.attemptID)
      }

      try carrierPublication.publish(to: carrierURL)
      let condition = result.condition.runOrderValue

      try EvaluationDurablePublication.publish(
        EvaluationCanonicalJSON.data(fromJSONObject: [
          "attempt_id": result.attemptID,
          "block_index": slot.blockIndex,
          "block_order_key": slot.blockOrderKey,
          "condition": condition,
          "conversation_id": result.conversationID,
          "frozen_order_index": result.frozenOrderIndex,
          "frozen_order_key": result.frozenOrderKey,
          "lifecycle_generation": result.stage == EvaluationPageStage.sealedPostRestart.rawValue
            ? "post-restart" : "pre-restart",
          "lifecycle_receipt_digest": result.split == EvaluationPageSplit.sealed.rawValue
            ? lifecycleReceiptSHA256 : "",
          "lock_acquisition_id": lockAcquisitionID.uuidString.lowercased(),
          "original_attempt_evidence_sha256": originalEvidence,
          "process_uuid": result.processUUID.uuidString.lowercased(),
          "replacement_of_attempt_id": replacedAttempt,
          "replacement_ordinal": result.replacementOrdinal,
          "replicate": result.replicate,
          "result_or_envelope_sha256": attempt.resultOrEnvelopeSHA256,
          "stage": result.stage,
        ]),
        to: skeletonURL
      )

      try EvaluationPathSecurity.rejectSymlinkComponents(in: [scratch, recordURL])
      _ = try await artifacts.run(
        relativeExecutablePath: Self.pageRecordExecutablePath,
        arguments: [
          "--root", freeze.repositoryRoot,
          "--manifest", manifestURL.path,
          "--approved-manifest-sha256", freeze.receipt.manifest.sha256,
          "--source", fixture.sourceRelativePath,
          "--gold", fixture.goldRelativePath,
          "--attempt", attemptURL.path,
          "--carrier", carrierURL.path,
          "--skeleton", skeletonURL.path,
          "--output", recordURL.path,
        ],
        protectedOutputURLs: [recordURL],
        freeze: freeze,
        captureLimit: 128 * 1_024
      )

      try EvaluationPathSecurity.rejectSymlinkComponents(in: [scratch, recordURL])
      let recordData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: recordURL)

      guard
        let record = try JSONSerialization.jsonObject(with: recordData) as? [String: Any],
        record["attempt_id"] as? String == result.attemptID,
        record["carrier_receipt_sha256"] as? String == result.carrierReceiptSHA256
      else {
        throw EvaluationPagePipelineError.recordConstructionFailed(result.attemptID)
      }

      records.append(record)
      recordURLs.append(recordURL)
    }

    try await publishRecordBundle(recordURLs, to: outputURL, freeze: freeze)

    return records
  }

  // swiftlint:disable:next function_body_length
  func writeDevelopmentInputs(
    records: [[String: Any]],
    catalog: EvaluationPageFixtureCatalog,
    freeze: EvaluationFreezeContext,
    runsURL: URL,
    bundleURL: URL
  ) async throws {
    let development = catalog.fixtures.filter {
      $0.split == EvaluationPageSplit.development.rawValue
    }
    guard development.count == PageEvaluationContract.developmentFixtureCount else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }

    var sources: [[String: Any]] = []
    var golds: [[String: Any]] = []
    var taskIDs: [String: String] = [:]

    for fixture in development {
      let source = try protectedObject(
        relativePath: fixture.sourceRelativePath,
        freeze: freeze
      )
      let gold = try protectedObject(
        relativePath: fixture.goldRelativePath,
        freeze: freeze
      )

      guard source["fixture_id"] as? String == fixture.fixtureID,
        source["task_id"] as? String == fixture.taskID
      else {
        throw EvaluationPagePipelineError.invalidManifestContract
      }

      sources.append(source)
      golds.append(gold)
      taskIDs[fixture.fixtureID] = fixture.taskID
    }

    let runs: [[String: Any]] = try records.map { record in
      guard
        let fixtureID = record["fixture_id"] as? String,
        let replicate = CanonicalJSON.integer(record["replicate"]),
        let taskID = taskIDs[fixtureID],
        let attempt = record["attempt"],
        let score = record["score_result"]
      else {
        throw EvaluationPagePipelineError.invalidManifestContract
      }

      let runDigest = SHA256Digest.hex(Data("\(taskID):\(replicate)".utf8))

      return [
        "attempt": attempt,
        "fixture_id": fixtureID,
        "parsed_output": record["parsed_output"] ?? NSNull(),
        "replicate": replicate,
        "run_id": "run-\(runDigest.prefix(12))",
        "score_result": score,
      ]
    }

    let scratch = try privatePublicationDirectory(for: bundleURL)
    try await publishCanonicalComposite(
      draft: EvaluationCanonicalJSON.data(fromJSONObject: ["runs": runs]),
      draftURL: scratch.appendingPathComponent("runs-draft.json"),
      outputURL: runsURL,
      freeze: freeze
    )
    try await publishCanonicalComposite(
      draft: EvaluationCanonicalJSON.data(fromJSONObject: [
        "golds": golds, "runs": runs, "sources": sources,
      ]),
      draftURL: scratch.appendingPathComponent("bundle-draft.json"),
      outputURL: bundleURL,
      freeze: freeze
    )
  }

  private func privatePublicationDirectory(for outputURL: URL) throws -> URL {
    let directory = outputURL.deletingLastPathComponent().appendingPathComponent(
      "\(outputURL.deletingPathExtension().lastPathComponent)-parts",
      isDirectory: true
    )
    try EvaluationPathSecurity.ensurePrivateDirectory(at: directory)
    return directory
  }

  private func publishCanonicalComposite(
    draft: Data,
    draftURL: URL,
    outputURL: URL,
    freeze: EvaluationFreezeContext
  ) async throws {
    defer { try? FileManager.default.removeItem(at: draftURL) }
    try EvaluationDurablePublication.publish(draft, to: draftURL)
    _ = try await artifacts.run(
      relativeExecutablePath: Self.pageRecordExecutablePath,
      arguments: [
        "canonicalize",
        "--input", draftURL.path,
        "--output", outputURL.path,
      ],
      protectedOutputURLs: [outputURL],
      freeze: freeze,
      captureLimit: 128 * 1_024
    )
  }

  private func publishRecordBundle(
    _ records: [URL],
    to outputURL: URL,
    freeze: EvaluationFreezeContext
  ) async throws {
    let arguments = ["bundle"]
      + records.flatMap { ["--record", $0.path] }
      + ["--output", outputURL.path]
    _ = try await artifacts.run(
      relativeExecutablePath: Self.pageRecordExecutablePath,
      arguments: arguments,
      protectedOutputURLs: [outputURL],
      freeze: freeze,
      captureLimit: 128 * 1_024
    )
  }

  private func writeAttempt(_ result: EvaluationAttemptResult, to url: URL) throws {
    let runtimeOutcome: String
    switch result.outcome {
    case .completed, .toolContractFailure:
      runtimeOutcome = "completed"
    case .localOutputLimit:
      runtimeOutcome = "local_output_limit"
    case .budgetStopped where result.criticalCode == "tool_budget_stop":
      runtimeOutcome = "tool_budget_stop"
    default:
      throw EvaluationPagePipelineError.resultUnavailable(result.attemptID)
    }

    let toolEvents: [[String: Any]] = result.tools.map { event in
      let path: Any = event.path.map { $0 as Any } ?? NSNull()
      return [
        "name": event.name,
        "path": path,
        "status":
          event.status == EvaluationToolContract.succeededStatus
          ? EvaluationToolContract.succeededStatus : EvaluationToolContract.failedStatus,
      ]
    }

    let rawOutput: Any = result.rawOutput.map { $0 as Any } ?? NSNull()
    let requests: [[String: Any]] = result.http.responsesSends.map { request in
      [
        "body_byte_count": request.bodyByteCount,
        "body_sha256": request.bodySHA256,
        "normalized_structure_sha256": request.normalizedStructureSHA256,
        "requested_model": request.requestedModel.map { $0 as Any } ?? NSNull(),
        "sequence": request.sequence,
        "untrusted_fence_present": request.untrustedFencePresent,
        "untrusted_payload_sha256": request.untrustedPayloadSHA256.map { $0 as Any } ?? NSNull(),
      ]
    }

    try EvaluationDurablePublication.publish(
      EvaluationCanonicalJSON.data(fromJSONObject: [
        "raw_output": rawOutput,
        "responses_requests": requests,
        "runtime_outcome": runtimeOutcome,
        "tool_events": toolEvents,
      ]),
      to: url
    )
  }

  private func protectedObject(
    relativePath: String,
    freeze: EvaluationFreezeContext
  ) throws -> [String: Any] {
    guard let record = freeze.manifest.artifact(relativePath: relativePath) else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }

    let data: Data
    do {
      data = try EvaluationManifestBoundArtifactReader.read(
        relativePath: record.path,
        expectedByteCount: record.bytes,
        expectedSHA256: record.sha256,
        repositoryRoot: URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
      ).data
    } catch {
      throw EvaluationPagePipelineError.invalidManifestContract
    }

    guard
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }

    return object
  }
}
