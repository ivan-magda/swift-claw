import ClawCore
import Foundation

/// Single package controller seam for the frozen page experiment. The caller supplies only the
/// approved freeze-input record; attempt order, configurations, tools, model, and budgets come from
/// the verified manifest and runtime configuration.
package struct EvaluationPageExperiment: Sendable {
  private let freezeVerifier: any EvaluationFreezeVerifying
  let artifacts: any EvaluationProtectedArtifactRunning
  let controller: EvaluationController

  package init() {
    let verifier = EvaluationLiveFreezeVerifier()
    freezeVerifier = verifier
    artifacts = EvaluationProtectedArtifactRunner()
    controller = EvaluationController(freezeVerifier: verifier)
  }

  init(
    freezeVerifier: any EvaluationFreezeVerifying,
    artifacts: any EvaluationProtectedArtifactRunning,
    launcher: any EvaluationWorkerLaunching
  ) {
    self.freezeVerifier = freezeVerifier
    self.artifacts = artifacts
    controller = EvaluationController(launcher: launcher, freezeVerifier: freezeVerifier)
  }

  package func run(freezeInputsPath: String) async throws -> Data {
    let inputs = try EvaluationJSONFile.decode(
      EvaluationFreezeInputs.self,
      from: URL(fileURLWithPath: freezeInputsPath)
    )
    let freeze = try await freezeVerifier.verify(inputs)

    guard
      freeze.manifest.schemaVersion == PageEvaluationContract.schemaVersion,
      freeze.manifest.decision == "D6",
      freeze.manifest.experiment == "page-change"
    else {
      throw EvaluationPagePipelineError.invalidManifestContract
    }

    let paths = EvaluationController.PagePipelinePaths(
      evaluationRoot: freeze.runtime.evaluationRootURL
    )
    guard
      FileManager.default.fileExists(atPath: paths.root.path) == false,
      FileManager.default.fileExists(atPath: paths.result.path) == false
    else {
      throw EvaluationPagePipelineError.resultUnavailable("pipeline_state_exists")
    }

    try prepare(paths)

    let journal = try EvaluationControllerJournal.startNew(
      evaluationRoot: freeze.runtime.evaluationRootURL,
      manifestSHA256: freeze.receipt.manifest.sha256,
      freezeCommit: freeze.receipt.freezeCommit,
      fixedTimestamp: freeze.runtime.fixedTimestamp,
      journalName: "page-\(freeze.receipt.manifest.sha256).jsonl"
    )

    do {
      let runOrder = try EvaluationPageRunOrder.decode(
        freeze.runOrderJSON,
        approvedManifestSHA256: freeze.receipt.manifest.sha256
      )

      try EvaluationDurablePublication.publish(freeze.runOrderJSON, to: paths.runOrder)

      let conformance = try await runConformance(freeze: freeze, receiptURL: paths.conformance)
      guard
        conformance.passed == PageEvaluationContract.conformanceCaseCount,
        conformance.total == PageEvaluationContract.conformanceCaseCount
      else {
        throw EvaluationPagePipelineError.stageGateFailed("conformance")
      }

      return try await runVerified(
        inputs: inputs,
        freeze: freeze,
        runOrder: runOrder,
        paths: paths,
        journal: journal
      )
    } catch {
      do {
        try writeTerminalResult(for: error, journal: journal, paths: paths)
      } catch {
        throw EvaluationPagePipelineError.resultUnavailable("terminal_result")
      }
      throw error
    }
  }

  func runConformance(
    freeze: EvaluationFreezeContext,
    receiptURL: URL
  ) async throws -> EvaluationConformanceReceiptBinding {
    try EvaluationProtectedOutputGuard.prepare(outputs: [receiptURL])

    let pageRoot = URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
      .appendingPathComponent(EvaluationController.pageRootPath, isDirectory: true)
    let output = try await artifacts.run(
      relativeExecutablePath: "\(EvaluationController.pageRootPath)/artifacts/page-conformance",
      arguments: [pageRoot.path],
      protectedOutputURLs: [],
      freeze: freeze,
      captureLimit: 2 * 1_024 * 1_024
    )

    guard
      let object = try JSONSerialization.jsonObject(with: output) as? [String: Any],
      CanonicalJSON.integer(object["schema_version"]) == 1,
      CanonicalJSON.integer(object["passed"]) == PageEvaluationContract.conformanceCaseCount,
      CanonicalJSON.integer(object["total"]) == PageEvaluationContract.conformanceCaseCount,
      object["conformance_id"] is String
    else {
      throw EvaluationPagePipelineError.stageGateFailed("conformance")
    }

    try EvaluationProtectedOutputGuard.prepare(outputs: [receiptURL])
    try EvaluationDurablePublication.publish(output, to: receiptURL)

    return EvaluationConformanceReceiptBinding(
      passed: PageEvaluationContract.conformanceCaseCount,
      total: PageEvaluationContract.conformanceCaseCount
    )
  }
}

private struct EvaluationPageRunContext {
  let inputs: EvaluationFreezeInputs
  let freeze: EvaluationFreezeContext
  let runOrder: EvaluationPageRunOrder
  let paths: EvaluationController.PagePipelinePaths
  let journal: EvaluationControllerJournal
  let catalog: EvaluationPageFixtureCatalog
  let factory: EvaluationPageConfigurationFactory
  let executable: String
  let records: EvaluationPageRecordBuilder
}

private struct EvaluationPromotedPageLesson {
  let binding: EvaluationPageLessonBinding
  let installedURL: URL
  let promotionReceipt: EvaluationPagePromotionReceipt
}

private struct EvaluationSealedStageRun {
  let key: Data
  let preSlots: [EvaluationPageTaskSlot]
  let preAttempts: [EvaluationController.AcceptedAttempt]
  let postSlots: [EvaluationPageTaskSlot]
  let postAttempts: [EvaluationController.AcceptedAttempt]
  let publisherSlot: EvaluationPageTaskSlot
  let firstReloadSlot: EvaluationPageTaskSlot
  let lockWasReleased: Bool
}

// MARK: - Verified Pipeline

private extension EvaluationPageExperiment {
  func runVerified(
    inputs: EvaluationFreezeInputs,
    freeze: EvaluationFreezeContext,
    runOrder: EvaluationPageRunOrder,
    paths: EvaluationController.PagePipelinePaths,
    journal: EvaluationControllerJournal
  ) async throws -> Data {
    let context = try makeRunContext(
      inputs: inputs,
      freeze: freeze,
      runOrder: runOrder,
      paths: paths,
      journal: journal
    )
    var canary = EvaluationController.Accumulator()
    var page = EvaluationController.Accumulator()

    defer {
      _ = try? EvaluationJSONFile.write(canary.summary, to: paths.canarySummary)
      _ = try? EvaluationJSONFile.write(page.summary, to: paths.summary)
    }

    try await executeCanary(context: context, accumulator: &canary)
    inheritCanaryUsage(canary, into: &page)

    let developmentGate = try await executeDevelopment(
      context: context,
      accumulator: &page
    )
    if case .finish(let outcome) = developmentGate.decision {
      return try finish(
        outcome: outcome,
        canary: canary,
        page: page,
        journal: journal,
        paths: paths,
        developmentGate: paths.developmentGate
      )
    }

    guard
      let promoted = try await synthesizeAndInstallLesson(
        context: context,
        accumulator: &page
      )
    else {
      return try finish(
        outcome: .pageTaskSpecificFailure,
        canary: canary,
        page: page,
        journal: journal,
        paths: paths,
        developmentGate: paths.developmentGate,
        synthesisRejectionReport: paths.synthesisRejectionReport
      )
    }

    let regressionGate = try await executeRegression(
      context: context,
      lesson: promoted.binding,
      accumulator: &page
    )
    if case .finish(let outcome) = regressionGate.decision {
      return try finish(
        outcome: outcome,
        canary: canary,
        page: page,
        journal: journal,
        paths: paths,
        developmentGate: paths.developmentGate,
        promotionReceipt: paths.promotionReceipt,
        regressionGate: paths.regressionGate,
        regressionJointUnsealReceipt: paths.regressionJointUnsealReceipt
      )
    }

    let sealed = try await executeSealedAttempts(
      context: context,
      lesson: promoted,
      accumulator: &page
    )

    return try await finishSealed(
      context: context,
      run: sealed,
      canary: canary,
      page: page
    )
  }

  func makeRunContext(
    inputs: EvaluationFreezeInputs,
    freeze: EvaluationFreezeContext,
    runOrder: EvaluationPageRunOrder,
    paths: EvaluationController.PagePipelinePaths,
    journal: EvaluationControllerJournal
  ) throws -> EvaluationPageRunContext {
    let catalog = try EvaluationPageFixtureCatalog.load(freeze: freeze)
    let factory = EvaluationPageConfigurationFactory(
      freeze: freeze,
      freezeInputs: inputs,
      catalog: catalog,
      configurationDirectory: paths.configurations,
      resultDirectory: paths.results
    )

    let executable = URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true)
      .appendingPathComponent(freeze.runtime.executablePath).path

    return EvaluationPageRunContext(
      inputs: inputs,
      freeze: freeze,
      runOrder: runOrder,
      paths: paths,
      journal: journal,
      catalog: catalog,
      factory: factory,
      executable: executable,
      records: EvaluationPageRecordBuilder(artifacts: artifacts)
    )
  }

  func executeCanary(
    context: EvaluationPageRunContext,
    accumulator: inout EvaluationController.Accumulator
  ) async throws {
    _ = try await controller.executeCanary(
      EvaluationCanaryExecutionRequest(
        order: context.runOrder,
        factory: context.factory,
        executablePath: context.executable,
        journal: context.journal,
        configurationPaths: [context.paths.canaryProcessA, context.paths.canaryProcessB],
        evidenceURL: context.paths.canaryLifecycle
      ),
      accumulator: &accumulator
    )
    try EvaluationJSONFile.write(accumulator.summary, to: context.paths.canarySummary)
  }

  func inheritCanaryUsage(
    _ canary: EvaluationController.Accumulator,
    into page: inout EvaluationController.Accumulator
  ) {
    page.globalAccountedTokensBase = canary.accountedTokens
    page.globalResponsesSendsBase = canary.responsesSends
    page.globalAttemptsBase = canary.attempts
    page.globalFileReadsBase = canary.fileReads
  }
}

// MARK: - Development and Promotion

private extension EvaluationPageExperiment {
  func executeDevelopment(
    context: EvaluationPageRunContext,
    accumulator: inout EvaluationController.Accumulator
  ) async throws -> EvaluationPageGateStatus {
    let slots = context.runOrder.taskSlots.filter {
      $0.stage == EvaluationPageStage.development.rawValue
    }
    let development = try await controller.executeBlocks(
      context.factory.makeBlocks(
        slots: slots,
        lesson: try EvaluationPageLessonBinding.clean()
      ),
      executablePath: context.executable,
      freezeInputs: context.inputs,
      freeze: context.freeze,
      limits: PageEvaluationContract.pageLimits,
      sealedOutputKey: nil,
      journal: context.journal,
      accumulator: &accumulator
    )

    guard
      accumulator.stopReason == nil,
      development.count == PageEvaluationContract.pageDevelopmentPlannedAttempts
    else {
      throw EvaluationPagePipelineError.resultUnavailable("development")
    }

    let developmentRecords = try await context.records.writeBundle(
      attempts: try unsealed(development),
      runOrder: context.runOrder,
      catalog: context.catalog,
      freeze: context.freeze,
      lifecycleReceiptSHA256: "",
      outputURL: context.paths.developmentRecords
    )

    try context.records.writeDevelopmentInputs(
      records: developmentRecords,
      catalog: context.catalog,
      freeze: context.freeze,
      runsURL: context.paths.developmentRuns,
      bundleURL: context.paths.developmentBundle
    )

    return try await aggregate(
      stage: .development,
      records: context.paths.developmentRecords,
      output: context.paths.developmentGate,
      inputs: context.inputs,
      freeze: context.freeze,
      paths: context.paths
    )
  }

  func synthesizeAndInstallLesson(
    context: EvaluationPageRunContext,
    accumulator: inout EvaluationController.Accumulator
  ) async throws -> EvaluationPromotedPageLesson? {
    try await buildSynthesisInput(freeze: context.freeze, paths: context.paths)
    let synthesis = try await runSynthesis(
      factory: context.factory,
      slot: context.runOrder.synthesis,
      executable: context.executable,
      inputs: context.inputs,
      freeze: context.freeze,
      journal: context.journal,
      page: &accumulator,
      paths: context.paths
    )

    let promotion = try await promote(
      synthesis: synthesis,
      freeze: context.freeze,
      paths: context.paths
    )

    guard case .promoted(let receipt) = promotion else {
      return nil
    }

    let promotedData = try EvaluationPathSecurity.readRegularSingleLinkFile(
      at: context.paths.promotedTemporary
    )

    let installed = try EvaluationWorkspaceMaterializer.installPromotedLessonSet(
      promotedData,
      receipt: receipt,
      stateRoot: context.freeze.runtime.evaluationRootURL.appendingPathComponent(
        PageEvaluationContract.stateDirectoryName,
        isDirectory: true
      )
    )

    let binding = try EvaluationPageLessonBinding.promoted(
      source: .artifact,
      artifactURL: installed,
      promotionReceiptURL: context.paths.promotionReceipt,
      promotionReceipt: receipt
    )

    return EvaluationPromotedPageLesson(
      binding: binding,
      installedURL: installed,
      promotionReceipt: receipt
    )
  }
}

// MARK: - Regression

private extension EvaluationPageExperiment {
  func executeRegression(
    context: EvaluationPageRunContext,
    lesson: EvaluationPageLessonBinding,
    accumulator: inout EvaluationController.Accumulator
  ) async throws -> EvaluationPageGateStatus {
    let slots = context.runOrder.taskSlots.filter {
      $0.stage == EvaluationPageStage.regression.rawValue
    }
    let key = EvaluationSealedResultStore.makeEphemeralKey()

    let attempts = try await controller.executeBlocks(
      context.factory.makeBlocks(slots: slots, lesson: lesson),
      executablePath: context.executable,
      freezeInputs: context.inputs,
      freeze: context.freeze,
      limits: PageEvaluationContract.pageLimits,
      sealedOutputKey: key,
      journal: context.journal,
      accumulator: &accumulator
    )

    guard
      accumulator.stopReason == nil,
      attempts.count == PageEvaluationContract.pageRegressionPlannedAttempts
    else {
      throw EvaluationPagePipelineError.resultUnavailable("regression")
    }

    let unsealed = try EvaluationSealedResultStore.jointlyUnseal(
      accepted: attempts,
      slots: slots,
      keyData: key,
      manifestSHA256: context.freeze.receipt.manifest.sha256,
      receiptURL: context.paths.regressionJointUnsealReceipt
    )

    _ = try await context.records.writeBundle(
      attempts: unsealed.attempts,
      runOrder: context.runOrder,
      catalog: context.catalog,
      freeze: context.freeze,
      lifecycleReceiptSHA256: "",
      outputURL: context.paths.regressionRecords
    )

    return try await aggregate(
      stage: .regression,
      records: context.paths.regressionRecords,
      output: context.paths.regressionGate,
      inputs: context.inputs,
      freeze: context.freeze,
      paths: context.paths
    )
  }
}

// MARK: - Sealed Restart

private extension EvaluationPageExperiment {
  func executeSealedAttempts(
    context: EvaluationPageRunContext,
    lesson: EvaluationPromotedPageLesson,
    accumulator: inout EvaluationController.Accumulator
  ) async throws -> EvaluationSealedStageRun {
    let key = EvaluationSealedResultStore.makeEphemeralKey()
    let preSlots = context.runOrder.taskSlots.filter {
      $0.stage == EvaluationPageStage.sealedPreRestart.rawValue
    }
    let restartSlots = try context.runOrder.restartLifecycleSlots()
    let preAttempts = try await controller.executeBlocks(
      context.factory.makeBlocks(
        slots: preSlots,
        lesson: lesson.binding,
        publishOrderKey: restartSlots.publisher.orderKey
      ),
      executablePath: context.executable,
      freezeInputs: context.inputs,
      freeze: context.freeze,
      limits: PageEvaluationContract.pageLimits,
      sealedOutputKey: key,
      journal: context.journal,
      accumulator: &accumulator
    )

    guard
      accumulator.stopReason == nil,
      preAttempts.count == PageEvaluationContract.pageSealedPreRestartPlannedAttempts
    else {
      throw EvaluationPagePipelineError.resultUnavailable("sealed_pre_restart")
    }

    let lockWasReleased = try EvaluationWorkerLifecycle.proveProductionLockIsFree(
      stateRoot: context.freeze.runtime.evaluationRootURL.appendingPathComponent(
        PageEvaluationContract.stateDirectoryName,
        isDirectory: true
      )
    )

    try EvaluationController.rotateToEmptyWorkspace(
      context.freeze.runtime.workspaceRootURL,
      evaluationRoot: context.freeze.runtime.evaluationRootURL
    )

    let durableLesson = try EvaluationPageLessonBinding.promoted(
      source: .durableActive,
      artifactURL: lesson.installedURL,
      promotionReceiptURL: context.paths.promotionReceipt,
      promotionReceipt: lesson.promotionReceipt
    )
    let postSlots = context.runOrder.taskSlots.filter {
      $0.stage == EvaluationPageStage.sealedPostRestart.rawValue
    }
    let postAttempts = try await controller.executeBlocks(
      context.factory.makeBlocks(slots: postSlots, lesson: durableLesson),
      executablePath: context.executable,
      freezeInputs: context.inputs,
      freeze: context.freeze,
      limits: PageEvaluationContract.pageLimits,
      sealedOutputKey: key,
      journal: context.journal,
      accumulator: &accumulator
    )

    guard
      accumulator.stopReason == nil,
      postAttempts.count == PageEvaluationContract.pageSealedPostRestartPlannedAttempts
    else {
      throw EvaluationPagePipelineError.resultUnavailable("sealed_post_restart")
    }

    return EvaluationSealedStageRun(
      key: key,
      preSlots: preSlots,
      preAttempts: preAttempts,
      postSlots: postSlots,
      postAttempts: postAttempts,
      publisherSlot: restartSlots.publisher,
      firstReloadSlot: restartSlots.firstReload,
      lockWasReleased: lockWasReleased
    )
  }

  func finishSealed(
    context: EvaluationPageRunContext,
    run: EvaluationSealedStageRun,
    canary: EvaluationController.Accumulator,
    page: EvaluationController.Accumulator
  ) async throws -> Data {
    let lifecycle = try EvaluationPageRestartLifecycleReceipt(
      publisher: sealedReceipt(in: run.preAttempts, orderKey: run.publisherSlot.orderKey),
      firstReload: sealedReceipt(in: run.postAttempts, orderKey: run.firstReloadSlot.orderKey),
      publisherSlot: run.publisherSlot,
      firstReloadSlot: run.firstReloadSlot,
      lockWasReleased: run.lockWasReleased
    )
    let lifecycleDigest = try lifecycle.publish(to: context.paths.lifecycleReceipt)

    let unsealed = try EvaluationSealedResultStore.jointlyUnseal(
      accepted: run.preAttempts + run.postAttempts,
      slots: run.preSlots + run.postSlots,
      keyData: run.key,
      manifestSHA256: context.freeze.receipt.manifest.sha256,
      receiptURL: context.paths.jointUnsealReceipt
    )

    _ = try await context.records.writeBundle(
      attempts: unsealed.attempts,
      runOrder: context.runOrder,
      catalog: context.catalog,
      freeze: context.freeze,
      lifecycleReceiptSHA256: lifecycleDigest,
      outputURL: context.paths.sealedRecords
    )

    let gate = try await aggregate(
      stage: .sealed,
      records: context.paths.sealedRecords,
      output: context.paths.sealedGate,
      inputs: context.inputs,
      freeze: context.freeze,
      paths: context.paths
    )

    guard case .finish(let outcome) = gate.decision else {
      throw EvaluationPagePipelineError.stageGateReceiptInvalid(
        EvaluationPageSplit.sealed.rawValue
      )
    }

    return try finish(
      outcome: outcome,
      canary: canary,
      page: page,
      journal: context.journal,
      paths: context.paths,
      developmentGate: context.paths.developmentGate,
      promotionReceipt: context.paths.promotionReceipt,
      regressionGate: context.paths.regressionGate,
      regressionJointUnsealReceipt: context.paths.regressionJointUnsealReceipt,
      sealedGate: context.paths.sealedGate,
      lifecycleReceipt: context.paths.lifecycleReceipt,
      jointUnsealReceipt: context.paths.jointUnsealReceipt
    )
  }
}
