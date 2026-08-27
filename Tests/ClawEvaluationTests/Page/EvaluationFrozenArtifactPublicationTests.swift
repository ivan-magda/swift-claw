import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationFrozenArtifactPublicationTests {
  @Test func recordBuilderPublishesTheClosedCarrierBoundToTheWorkspaceDigest() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = try makeEvaluationConfiguration(root: root)
    let configuration = configured.configuration
    let materialization = try EvaluationWorkspaceMaterializer.reset(configuration: configuration)
    let processUUID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
    let result = makeEvaluationResult(
      configuration: configuration,
      replacementDisposition: .ineligible,
      workspace: materialization,
      processUUID: processUUID
    )
    let fixture = EvaluationPageFixture(
      fixtureID: configuration.fixtureID,
      split: configuration.split,
      sourceRelativePath: "sources/development/source.json",
      goldRelativePath: "gold/development/gold.json",
      taskID: configuration.taskID,
      sourceSHA256: configuration.sourceSHA256
    )
    let catalog = EvaluationPageFixtureCatalog(
      fixtures: [fixture],
      byID: [fixture.fixtureID: fixture]
    )
    let slot = EvaluationPageTaskSlot(
      stage: configuration.stage,
      split: configuration.split,
      orderIndex: configuration.frozenOrderIndex,
      blockIndex: 0,
      orderKey: configuration.frozenOrderKey,
      blockOrderKey: String(repeating: "b", count: 64),
      fixtureID: configuration.fixtureID,
      replicate: configuration.replicate,
      condition: configuration.condition.runOrderValue,
      lessonSource: configuration.lessonSource,
      workerProcessKey: String(repeating: "e", count: 64)
    )
    let runOrder = EvaluationPageRunOrder(
      canaryProcesses: [],
      taskSlots: [slot],
      synthesis: EvaluationPageSynthesisSlot(
        orderKey: String(repeating: "1", count: 64),
        workerProcessKey: String(repeating: "2", count: 64),
        promptPath: "prompts/synthesis.md"
      )
    )
    let frozen = try makeEvaluationFreeze(root: root, configurations: [configuration])
    let artifactOutput = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "attempt_id": result.attemptID,
      "carrier_receipt_sha256": result.carrierReceiptSHA256,
    ])
    let artifactRunner = ScriptedEvaluationProtectedArtifactRunner(output: artifactOutput)
    let builder = EvaluationPageRecordBuilder(artifacts: artifactRunner)
    let outputURL = configuration.evaluationRootURL
      .appendingPathComponent("pipeline", isDirectory: true)
      .appendingPathComponent("development-records.json")
    let expectedCarrierData = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "input_sha256": materialization.carrierReceipt.inputSHA256,
      "lesson_ids": materialization.carrierReceipt.lessonIDs,
      "lesson_set_id": materialization.carrierReceipt.lessonSetID,
      "lesson_set_sha256": materialization.carrierReceipt.lessonSetSHA256,
      "lesson_source": materialization.carrierReceipt.lessonSource.rawValue,
      "promotion_receipt_sha256": NSNull(),
      "source_sha256": materialization.carrierReceipt.sourceSHA256,
      "task_id": materialization.carrierReceipt.taskID,
    ])

    // when
    _ = try await builder.writeBundle(
      attempts: [
        EvaluationRecordedAttempt(
          result: result,
          resultOrEnvelopeSHA256: String(repeating: "f", count: 64)
        )
      ],
      runOrder: runOrder,
      catalog: catalog,
      freeze: frozen.context,
      lifecycleReceiptSHA256: "",
      outputURL: outputURL
    )

    // then
    let invocations = await artifactRunner.invocations
    let invocation = try #require(invocations.first)
    let carrierFlagIndex = try #require(invocation.arguments.firstIndex(of: "--carrier"))
    let carrierPathIndex = carrierFlagIndex + 1
    try #require(invocation.arguments.indices.contains(carrierPathIndex))
    let carrierURL = URL(fileURLWithPath: invocation.arguments[carrierPathIndex])
    let carrierData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: carrierURL)
    #expect(carrierData == expectedCarrierData)
    #expect(SHA256Digest.hex(carrierData) == result.carrierReceiptSHA256)
  }

  @Test func lifecyclePublicationUsesCanonicalLowercaseIdentifiersAndReturnsItsDigest() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let promotion = try makeEvaluationPromotionFixture()
    let activeLessons = try #require(
      JSONSerialization.jsonObject(with: promotion.activeLessonData) as? [String: Any]
    )
    let lessonSetID = promotion.receipt.activeLessonSetID
    let lessonIDs = promotion.receipt.lessonIDs
    let promotionReceiptSHA256 = SHA256Digest.hex(promotion.receiptData)
    let promotionReceiptURL = root.appendingPathComponent("promotion.json")
    try EvaluationDurablePublication.publish(promotion.receiptData, to: promotionReceiptURL)
    let publisherOrderKey = String(repeating: "3", count: 64)
    let firstReloadOrderKey = String(repeating: "4", count: 64)
    let publisherConfiguration = try makeEvaluationConfiguration(
      root: root,
      attemptID: "publisher-attempt",
      fixtureID: "pc-sealed-01",
      split: EvaluationPageSplit.sealed.rawValue,
      stage: EvaluationPageStage.sealedPreRestart.rawValue,
      frozenOrderIndex: 1,
      frozenOrderKey: publisherOrderKey,
      condition: .lessonConditioned,
      lessonSource: .artifact,
      activeLessons: activeLessons,
      promotionReceiptPath: promotionReceiptURL.path,
      promotionReceiptSHA256: promotionReceiptSHA256
    ).configuration
    let firstReloadConfiguration = try makeEvaluationConfiguration(
      root: root,
      attemptID: "first-reload-attempt",
      fixtureID: "pc-sealed-01",
      split: EvaluationPageSplit.sealed.rawValue,
      stage: EvaluationPageStage.sealedPostRestart.rawValue,
      frozenOrderIndex: 0,
      frozenOrderKey: firstReloadOrderKey,
      condition: .postRestartLessonConditioned,
      lessonSource: .durableActive,
      activeLessons: activeLessons,
      promotionReceiptPath: promotionReceiptURL.path,
      promotionReceiptSHA256: promotionReceiptSHA256
    ).configuration
    let publisherProcessUUID = try #require(
      UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
    )
    let publisherLockUUID = try #require(
      UUID(uuidString: "11111111-2222-4333-8444-555555555555")
    )
    let firstReloadProcessUUID = try #require(
      UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF")
    )
    let firstReloadLockUUID = try #require(
      UUID(uuidString: "99999999-AAAA-4BBB-8CCC-DDDDDDDDDDDD")
    )
    let publisherResult = try makeCanaryEvidenceResult(
      configuration: publisherConfiguration,
      processUUID: publisherProcessUUID,
      sessionID: 11,
      lessonSetID: lessonSetID,
      lessonIDs: lessonIDs,
      lockAcquisitionID: publisherLockUUID
    )
    let firstReloadResult = try makeCanaryEvidenceResult(
      configuration: firstReloadConfiguration,
      processUUID: firstReloadProcessUUID,
      sessionID: 12,
      lessonSetID: lessonSetID,
      lessonIDs: lessonIDs,
      lockAcquisitionID: firstReloadLockUUID
    )
    let publisherReceipt = EvaluationSealedAttemptReceipt(
      result: publisherResult,
      lockAcquisitionID: publisherLockUUID,
      envelopePath: root.appendingPathComponent("publisher.sealed").path,
      envelope: Data("publisher-envelope".utf8),
      plaintext: Data("publisher-plaintext".utf8)
    )
    let firstReloadReceipt = EvaluationSealedAttemptReceipt(
      result: firstReloadResult,
      lockAcquisitionID: firstReloadLockUUID,
      envelopePath: root.appendingPathComponent("first-reload.sealed").path,
      envelope: Data("first-reload-envelope".utf8),
      plaintext: Data("first-reload-plaintext".utf8)
    )
    let blockOrderKey = String(repeating: "5", count: 64)
    let publisherSlot = Self.lifecycleSlot(
      configuration: publisherConfiguration,
      blockOrderKey: blockOrderKey,
      workerProcessKey: String(repeating: "6", count: 64)
    )
    let firstReloadSlot = Self.lifecycleSlot(
      configuration: firstReloadConfiguration,
      blockOrderKey: blockOrderKey,
      workerProcessKey: String(repeating: "7", count: 64)
    )
    let receipt = try EvaluationPageRestartLifecycleReceipt(
      publisher: publisherReceipt,
      firstReload: firstReloadReceipt,
      publisherSlot: publisherSlot,
      firstReloadSlot: firstReloadSlot,
      lockWasReleased: true
    )
    let outputURL = root.appendingPathComponent("page-restart-lifecycle.json")
    let expectedData = try EvaluationCanonicalJSON.data(fromJSONObject: [
      "durable_lesson_digest": firstReloadReceipt.lessonSetDigest,
      "durable_lesson_ids": lessonIDs,
      "durable_lesson_set_id": lessonSetID,
      "first_reload_attempt_id": firstReloadReceipt.attemptID,
      "first_reload_frozen_order_key": firstReloadOrderKey,
      "first_reload_lock_acquisition_id": firstReloadLockUUID.uuidString.lowercased(),
      "first_reload_process_uuid": firstReloadProcessUUID.uuidString.lowercased(),
      "input_was_regenerated": true,
      "lock_was_reacquired": true,
      "lock_was_released": true,
      "publisher_attempt_id": publisherReceipt.attemptID,
      "publisher_frozen_order_key": publisherOrderKey,
      "publisher_lock_acquisition_id": publisherLockUUID.uuidString.lowercased(),
      "publisher_process_uuid": publisherProcessUUID.uuidString.lowercased(),
      "schema_version": PageEvaluationContract.schemaVersion,
      "workspace_was_empty": true,
    ])

    // when
    let publishedDigest = try receipt.publish(to: outputURL)

    // then
    let publishedData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: outputURL)
    #expect(publishedData == expectedData)
    #expect(publishedDigest == SHA256Digest.hex(publishedData))
  }
}

// MARK: - Fixtures

private extension EvaluationFrozenArtifactPublicationTests {
  static func lifecycleSlot(
    configuration: EvaluationAttemptConfiguration,
    blockOrderKey: String,
    workerProcessKey: String
  ) -> EvaluationPageTaskSlot {
    EvaluationPageTaskSlot(
      stage: configuration.stage,
      split: configuration.split,
      orderIndex: configuration.frozenOrderIndex,
      blockIndex: 0,
      orderKey: configuration.frozenOrderKey,
      blockOrderKey: blockOrderKey,
      fixtureID: configuration.fixtureID,
      replicate: configuration.replicate,
      condition: configuration.condition.runOrderValue,
      lessonSource: configuration.lessonSource,
      workerProcessKey: workerProcessKey
    )
  }
}
