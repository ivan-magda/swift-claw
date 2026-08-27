import ClawCore
import Foundation

extension EvaluationController {
  struct WrittenInvocation {
    let invocationID: UUID
    let configurationSHA256: String
    let path: String
  }

  static func validate(
    configuration: EvaluationAttemptConfiguration,
    against freeze: EvaluationFreezeContext
  ) throws {
    let runtime = freeze.runtime
    let receipt = freeze.receipt
    guard
      configuration.evaluationRoot == runtime.evaluationRoot,
      configuration.fixedTimestamp == runtime.fixedTimestamp,
      configuration.providerReference == runtime.providerReference,
      configuration.wireModel == runtime.wireModel,
      configuration.transportMode == runtime.transportMode,
      configuration.fallbackReference == runtime.fallbackReference,
      configuration.expectedPolicyVersion == runtime.expectedPolicyVersion
    else {
      throw EvaluationControllerError.planPathMismatch
    }
    let approval = configuration.approval
    guard
      approval.manifestSHA256 == receipt.manifest.sha256,
      approval.approvedManifestSHA256 == receipt.manifest.sha256,
      approval.commentID == receipt.comment.id,
      approval.commentNodeID == receipt.comment.nodeID,
      approval.authorLogin == receipt.comment.author.login,
      approval.authorID == receipt.comment.author.id,
      approval.authorNodeID == receipt.comment.author.nodeID,
      approval.createdAt == receipt.comment.createdAt,
      approval.updatedAt == receipt.comment.updatedAt,
      approval.approvalBodySHA256 == receipt.comment.bodySHA256
    else {
      throw EvaluationControllerError.approvalBindingMismatch
    }
    guard configuration.provenance.freezeCommit == receipt.freezeCommit else {
      throw EvaluationControllerError.provenanceBindingMismatch("freeze_commit")
    }
    try compare(
      configuration.provenance.executableSHA256,
      receipt.executable.sha256,
      name: "executable"
    )
    let categories: [(String, String)] = [
      ("runtime_sources", configuration.provenance.runtimeSourcesSHA256),
      ("harness_sources", configuration.provenance.harnessSourcesSHA256),
      ("dependencies", configuration.provenance.dependenciesSHA256),
      ("configuration", configuration.provenance.configurationSHA256),
      ("model", configuration.provenance.modelSHA256),
      ("retry", configuration.provenance.retrySHA256),
      ("output", configuration.provenance.outputSHA256),
      ("prompts", configuration.provenance.promptsSHA256),
      ("schemas", configuration.provenance.schemasSHA256),
      ("scorer", configuration.provenance.scorerSHA256),
      ("splits", configuration.provenance.splitsSHA256),
      ("run_order", configuration.provenance.runOrderSHA256),
    ]
    for (name, observed) in categories {
      guard let expected = freeze.manifest.categories[name]?.sha256, expected == observed else {
        throw EvaluationControllerError.provenanceBindingMismatch(name)
      }
    }

    let root = URL(fileURLWithPath: freeze.repositoryRoot, isDirectory: true).standardizedFileURL
    let promptRole =
      configuration.stage == EvaluationPageStage.synthesis.rawValue ? "synthesis" : "task"
    guard
      let stage = EvaluationPageStage(rawValue: configuration.stage),
      freeze.runtime.fileReadAllowlists.expectedFileName(for: stage)
        == configuration.expectedInputFileName,
      let prompt = freeze.manifest.artifact(role: promptRole, category: "prompts"),
      root.appendingPathComponent(prompt.path).standardizedFileURL
        == URL(fileURLWithPath: configuration.taskPromptPath).standardizedFileURL,
      prompt.sha256 == configuration.taskPromptSHA256
    else {
      throw EvaluationControllerError.artifactBindingMismatch("task_prompt")
    }
    try validateProtectedSource(configuration, root: root, manifest: freeze.manifest)
    try validateLessonArtifact(configuration, root: root, manifest: freeze.manifest)
  }

  static func validateProtectedSource(
    _ configuration: EvaluationAttemptConfiguration,
    root: URL,
    manifest: EvaluationFreezeManifest
  ) throws {
    let source = URL(fileURLWithPath: configuration.sourceArtifactPath).standardizedFileURL
    if configuration.stage == EvaluationPageStage.synthesis.rawValue {
      let expected = configuration.evaluationRootURL
        .appendingPathComponent("pipeline", isDirectory: true)
        .appendingPathComponent("synthesis-input.json", isDirectory: false)
        .standardizedFileURL
      guard
        source == expected,
        EvaluationPathSecurity.isStrictlyContained(
          source,
          under: configuration.evaluationRootURL
        ),
        let data = try? EvaluationPathSecurity.readRegularSingleLinkFile(at: source),
        SHA256Digest.hex(data) == configuration.sourceSHA256,
        configuration.inputSHA256 == configuration.sourceSHA256
      else {
        throw EvaluationControllerError.artifactBindingMismatch("synthesis_input")
      }
      return
    }
    guard
      let relative = EvaluationPathSecurity.relativePath(of: source, under: root),
      let artifact = manifest.artifact(relativePath: relative),
      artifact.sha256 == configuration.sourceSHA256
    else {
      throw EvaluationControllerError.artifactBindingMismatch("source")
    }
  }

  static func validateLessonArtifact(
    _ configuration: EvaluationAttemptConfiguration,
    root: URL,
    manifest: EvaluationFreezeManifest
  ) throws {
    guard configuration.lessonSource != .clean else { return }
    if configuration.stage == EvaluationPageStage.canary.rawValue,
      configuration.lessonSource == .durableActive
    {
      guard
        let protected = manifest.artifact(
          role: "canary_nonempty_lessons",
          category: "configuration"
        ),
        protected.sha256 == configuration.lessonSetDigest
      else {
        throw EvaluationControllerError.artifactBindingMismatch("canary_durable_lesson")
      }
      return
    }
    let lesson: URL
    switch configuration.lessonSource {
    case .clean:
      return
    case .artifact:
      guard let path = configuration.lessonArtifactPath else {
        throw EvaluationControllerError.artifactBindingMismatch("lesson")
      }
      lesson = URL(fileURLWithPath: path).standardizedFileURL
    case .durableActive:
      lesson =
        configuration.stateRootURL
        .appendingPathComponent(PageEvaluationContract.lessonSetsDirectoryName, isDirectory: true)
        .appendingPathComponent("\(configuration.lessonSetDigest).json", isDirectory: false)
        .standardizedFileURL
    }
    if let relative = EvaluationPathSecurity.relativePath(of: lesson, under: root),
      let artifact = manifest.artifact(relativePath: relative)
    {
      guard
        configuration.stage == EvaluationPageStage.canary.rawValue,
        artifact.sha256 == configuration.lessonSetDigest
      else {
        throw EvaluationControllerError.artifactBindingMismatch("lesson")
      }
      return
    }
    let sets = configuration.stateRootURL.appendingPathComponent(
      PageEvaluationContract.lessonSetsDirectoryName,
      isDirectory: true
    )
    guard
      EvaluationPathSecurity.isStrictlyContained(lesson, under: sets),
      lesson.lastPathComponent == "\(configuration.lessonSetDigest).json",
      let data = try? EvaluationPathSecurity.readRegularSingleLinkFile(at: lesson),
      SHA256Digest.hex(data) == configuration.lessonSetDigest,
      let promotionPath = configuration.promotionReceiptPath,
      let promotionDigest = configuration.promotionReceiptSHA256,
      validatePromotionReceipt(
        at: URL(fileURLWithPath: promotionPath),
        digest: promotionDigest,
        activeLessonData: data,
        activeLessonDigest: configuration.lessonSetDigest,
        evaluationRoot: configuration.evaluationRootURL
      )
    else {
      throw EvaluationControllerError.artifactBindingMismatch("promoted_lesson")
    }
  }

  static func validatePromotionReceipt(
    at receiptURL: URL,
    digest: String,
    activeLessonData: Data,
    activeLessonDigest: String,
    evaluationRoot: URL
  ) -> Bool {
    guard
      EvaluationPathSecurity.isStrictlyContained(receiptURL, under: evaluationRoot),
      let receiptData = try? EvaluationPathSecurity.readRegularSingleLinkFile(at: receiptURL),
      SHA256Digest.hex(receiptData) == digest,
      let receipt = try? JSONSerialization.jsonObject(with: receiptData) as? [String: Any],
      Set(receipt.keys)
        == Set([
          "schema_version", "promotion_id", "development_bundle_sha256",
          "synthesis_input_sha256", "synthesis_transcript_sha256", "lint_rules_sha256",
          "lint_report_sha256", "candidate_sha256", "active_lesson_set_sha256",
          "active_lesson_set_id", "lesson_ids", "canonical_byte_count",
        ]),
      CanonicalJSON.integer(receipt["schema_version"]) == 1,
      receipt["active_lesson_set_sha256"] as? String == activeLessonDigest,
      CanonicalJSON.integer(receipt["canonical_byte_count"]) == activeLessonData.count,
      let lesson = try? JSONSerialization.jsonObject(with: activeLessonData) as? [String: Any],
      receipt["active_lesson_set_id"] as? String == lesson["lesson_set_id"] as? String,
      let lessons = lesson["lessons"] as? [[String: Any]],
      receipt["lesson_ids"] as? [String]
        == lessons.compactMap({ $0["lesson_id"] as? String }),
      lessons.count == (receipt["lesson_ids"] as? [String])?.count
    else {
      return false
    }
    return true
  }

  static func compare(_ observed: String, _ expected: String, name: String) throws {
    guard observed == expected else {
      throw EvaluationControllerError.provenanceBindingMismatch(name)
    }
  }

  static func result(
    _ result: EvaluationAttemptResult,
    matches configuration: EvaluationAttemptConfiguration
  ) -> Bool {
    result.schemaVersion == PageEvaluationContract.schemaVersion
      && result.attemptID == configuration.attemptID
      && result.fixtureID == configuration.fixtureID
      && result.taskID == configuration.taskID
      && result.stage == configuration.stage
      && result.split == configuration.split
      && result.frozenOrderIndex == configuration.frozenOrderIndex
      && result.frozenOrderKey == configuration.frozenOrderKey
      && result.replicate == configuration.replicate
      && result.condition == configuration.condition
      && result.protocolSHA256 == configuration.protocolSHA256
      && result.manifestSHA256 == configuration.approval.manifestSHA256
      && result.approval == configuration.approval
      && result.provenance == configuration.provenance
      && result.inputSHA256 == configuration.inputSHA256
      && result.taskPromptSHA256 == configuration.taskPromptSHA256
      && result.lessonSetDigest == configuration.lessonSetDigest
      && result.policyVersion == configuration.expectedPolicyVersion
      && result.providerReference == configuration.providerReference
      && result.wireModel == configuration.wireModel
      && result.transportMode == configuration.transportMode
      && result.fallbackReference == configuration.fallbackReference
      && result.replacementOfAttemptID == configuration.replacementOfAttemptID
      && result.replacementOrdinal == configuration.replacementOrdinal
      && validAccounting(
        responsesSends: result.http.responsesSends.count,
        provenNotStartedResponsesSends: result.http.provenNotStartedResponsesSends,
        usage: result.usage,
        accountedTokens: result.accountedTokens
      )
  }

  static func sealedReceipt(
    _ receipt: EvaluationSealedAttemptReceipt,
    matches configuration: EvaluationAttemptConfiguration
  ) -> Bool {
    receipt.schemaVersion == PageEvaluationContract.schemaVersion
      && receipt.attemptID == configuration.attemptID
      && receipt.fixtureID == configuration.fixtureID
      && receipt.condition == configuration.condition
      && receipt.manifestSHA256 == configuration.approval.manifestSHA256
      && receipt.frozenOrderIndex == configuration.frozenOrderIndex
      && receipt.frozenOrderKey == configuration.frozenOrderKey
      && receipt.lessonSetDigest == configuration.lessonSetDigest
      && receipt.processID > 0
      && receipt.conversationID.isEmpty == false
      && receipt.inputWasRegenerated
      && URL(fileURLWithPath: receipt.envelopePath).standardizedFileURL
        == EvaluationSealedResultStore.envelopeURL(for: configuration.resultURL).standardizedFileURL
      && receipt.responsesSends >= 0
      && receipt.responsesSends <= PageEvaluationContract.maximumResponsesSendsPerAttempt
      && receipt.provenNotStartedResponsesSends >= 0
      && receipt.provenNotStartedResponsesSends <= receipt.responsesSends
      && receipt.credentialHTTPCalls >= 0
      && receipt.fileReads >= 0
      && receipt.fileReads <= PageEvaluationContract.runBudget.maxToolCalls
      && receipt.accountedTokens >= 0
      && validAccounting(
        responsesSends: receipt.responsesSends,
        provenNotStartedResponsesSends: receipt.provenNotStartedResponsesSends,
        usage: receipt.usage,
        accountedTokens: receipt.accountedTokens
      )
  }

  private static func validAccounting(
    responsesSends: Int,
    provenNotStartedResponsesSends: Int,
    usage: [EvaluationUsageRecord],
    accountedTokens: Int
  ) -> Bool {
    guard
      (0...PageEvaluationContract.maximumResponsesSendsPerAttempt).contains(responsesSends),
      provenNotStartedResponsesSends >= 0,
      provenNotStartedResponsesSends <= responsesSends,
      usage.count <= responsesSends - provenNotStartedResponsesSends,
      Set(usage.map(\.providerCallID)).count == usage.count,
      usage.allSatisfy({ row in
        row.promptTokens >= 0
          && row.completionTokens >= 0
          && row.totalTokens
            == SaturatingArithmetic.sum(row.promptTokens, row.completionTokens)
      }),
      accountedTokens >= 0
    else { return false }
    return accountedTokens
      == EvaluationResultAccounting.accountedTokens(
        responsesSends: responsesSends,
        provenNotStartedResponsesSends: provenNotStartedResponsesSends,
        usage: usage.map {
          EvaluationUsageAccountingRow(tokens: $0.totalTokens, isEstimated: $0.isEstimated)
        }
      )
  }

  static func progressEntry(
    _ entry: EvaluationAttemptProgressEntry,
    matches result: EvaluationAttemptResult,
    expectedInputFileName: String
  ) -> Bool {
    entry.attemptID == result.attemptID
      && entry.responsesRequests == result.http.responsesSends
      && entry.provenNotStartedResponsesSends
        == result.http.provenNotStartedResponsesSends
      && entry.credentialHTTPCalls == result.http.credentialHTTPCalls
      && entry.fileReads
        == EvaluationToolContract.observedFileReads(
          in: result.tools,
          expectedPath: expectedInputFileName
        )
      && entry.usage == result.usage
      && entry.accountedTokens == result.accountedTokens
  }

  static func progressEntry(
    _ entry: EvaluationAttemptProgressEntry,
    matches receipt: EvaluationSealedAttemptReceipt
  ) -> Bool {
    entry.attemptID == receipt.attemptID
      && entry.responsesRequests == receipt.responsesRequests
      && entry.provenNotStartedResponsesSends
        == receipt.provenNotStartedResponsesSends
      && entry.credentialHTTPCalls == receipt.credentialHTTPCalls
      && entry.fileReads == receipt.fileReads
      && entry.usage == receipt.usage
      && entry.accountedTokens == receipt.accountedTokens
  }

  static func isIntegrityFailure(_ result: EvaluationAttemptResult) -> Bool {
    isIntegrityFailure(result.outcome)
  }

  static func isIntegrityFailure(_ outcome: EvaluationAttemptOutcome) -> Bool {
    switch outcome {
    case .modelIdentityMismatch, .invalidProviderState, .policyMismatch, .harnessFailure:
      true
    default:
      false
    }
  }

  static func isIncompleteFailure(_ result: EvaluationAttemptResult) -> Bool {
    isIncompleteFailure(outcome: result.outcome, criticalCode: result.criticalCode)
  }

  static func isIncompleteFailure(_ receipt: EvaluationSealedAttemptReceipt) -> Bool {
    isIncompleteFailure(outcome: receipt.outcome, criticalCode: receipt.criticalCode)
  }

  private static func isIncompleteFailure(
    outcome: EvaluationAttemptOutcome,
    criticalCode: String?
  ) -> Bool {
    switch outcome {
    case .authenticationRequired, .accessDenied, .quotaLimited, .providerFailure:
      true
    case .budgetStopped:
      criticalCode == nil
    default:
      false
    }
  }

  static func terminalizeAfterResult(
    _ accumulator: inout Accumulator,
    limits: PageEvaluationContract.StageLimits
  ) {
    guard accumulator.stopReason == nil else { return }
    if accumulator.accountedTokens > limits.accountedTokenThreshold {
      accumulator.stopReason = "stage_accounted_token_threshold_crossed"
    } else if SaturatingArithmetic.sum(
      accumulator.globalAccountedTokensBase,
      accumulator.accountedTokens
    ) > PageEvaluationContract.globalAccountedTokenThreshold {
      accumulator.stopReason = "global_accounted_token_threshold_crossed"
    } else if accumulator.responsesSends > limits.maximumResponsesSends {
      accumulator.stopReason = "stage_responses_send_cap_exceeded"
    } else if SaturatingArithmetic.sum(
      accumulator.globalResponsesSendsBase,
      accumulator.responsesSends
    ) > PageEvaluationContract.globalMaximumResponsesSends {
      accumulator.stopReason = "global_responses_send_cap_exceeded"
    } else if accumulator.attempts > limits.maximumAttempts {
      accumulator.stopReason = "stage_attempt_cap_exceeded"
    } else if SaturatingArithmetic.sum(
      accumulator.globalAttemptsBase,
      accumulator.attempts
    ) > PageEvaluationContract.globalMaximumAttempts {
      accumulator.stopReason = "global_attempt_cap_exceeded"
    } else if accumulator.fileReads > limits.maximumFileReads {
      accumulator.stopReason = "stage_file_read_cap_exceeded"
    } else if SaturatingArithmetic.sum(
      accumulator.globalFileReadsBase,
      accumulator.fileReads
    ) > PageEvaluationContract.globalMaximumFileReads {
      accumulator.stopReason = "global_file_read_cap_exceeded"
    }
  }

  static func validateReplacement(at replacementPath: String, of originalPath: String) throws {
    let original = try EvaluationJSONFile.decode(
      EvaluationAttemptConfiguration.self,
      from: URL(fileURLWithPath: originalPath)
    )
    let replacement = try EvaluationJSONFile.decode(
      EvaluationAttemptConfiguration.self,
      from: URL(fileURLWithPath: replacementPath)
    )
    try original.validate()
    try replacement.validate()
    let expectedResult = original.resultURL.deletingLastPathComponent()
      .appendingPathComponent("\(replacement.attemptID).json", isDirectory: false)
      .standardizedFileURL
    guard
      original.replacementOrdinal == 0,
      original.replacementOfAttemptID == nil,
      replacement.replacementOrdinal == 1,
      replacement.replacementOfAttemptID == original.attemptID,
      replacement.attemptID == "\(original.attemptID)-r1",
      replacement.resultURL.standardizedFileURL == expectedResult,
      try replacementProjection(replacement) == replacementProjection(original)
    else {
      throw EvaluationControllerError.replacementLineageMismatch
    }
  }

  static func resultEvidenceSHA256(configurationPath: String, sealed: Bool) throws -> String {
    let configuration = try EvaluationJSONFile.decode(
      EvaluationAttemptConfiguration.self,
      from: URL(fileURLWithPath: configurationPath)
    )
    let url =
      sealed
      ? EvaluationSealedResultStore.envelopeURL(for: configuration.resultURL)
      : configuration.resultURL
    return SHA256Digest.hex(try EvaluationPathSecurity.readRegularSingleLinkFile(at: url))
  }

  static func evidenceSHA256(_ event: EvaluationControllerJournalEvent) throws -> String {
    SHA256Digest.hex(try EvaluationCanonicalJSON.data(encoding: event))
  }

  private static func replacementProjection(
    _ configuration: EvaluationAttemptConfiguration
  ) throws -> Data {
    let encoded = try EvaluationCanonicalJSON.data(encoding: configuration)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
      throw EvaluationControllerError.replacementLineageMismatch
    }
    for key in EvaluationAttemptConfiguration.replacementLineageCodingKeys {
      object.removeValue(forKey: key.rawValue)
    }
    return try EvaluationCanonicalJSON.data(fromJSONObject: object)
  }

  static func writeInvocation(
    kind: EvaluationWorkerInvocationKind,
    configurationPath: String,
    freeze: EvaluationFreezeInputs,
    budget: EvaluationSendBudgetSnapshot,
    evaluationRoot: URL,
    journal: EvaluationControllerJournal,
    attemptIDs: [String],
    maximumResponsesSends: Int
  ) throws -> WrittenInvocation {
    let directory = evaluationRoot.appendingPathComponent("invocations", isDirectory: true)
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [evaluationRoot])
    try EvaluationPathSecurity.ensurePrivateDirectory(at: directory)
    let invocationID = UUID()
    let configurationSnapshot = try EvaluationWorkerConfigurationSnapshot.load(
      kind: kind,
      path: configurationPath
    )
    let core = EvaluationWorkerInvocationCore(
      kind: kind,
      configurationPath: configurationPath,
      configurationSHA256: configurationSnapshot.sha256,
      freeze: freeze,
      budget: budget
    )
    let reservation = try journal.reserve(
      invocationID: invocationID,
      invocationCoreSHA256: core.sha256,
      attemptIDs: attemptIDs,
      maximumResponsesSends: maximumResponsesSends
    )
    let authorization = EvaluationWorkerAuthorization(
      journalPath: journal.url.path,
      reservation: reservation,
      reservationSHA256: SHA256Digest.hex(try EvaluationCanonicalJSON.data(encoding: reservation))
    )
    let invocation = EvaluationWorkerInvocation(
      invocationID: invocationID,
      kind: kind,
      configurationPath: configurationPath,
      configurationSHA256: configurationSnapshot.sha256,
      freeze: freeze,
      budget: budget,
      authorization: authorization
    )
    try invocation.validate()
    let url = directory.appendingPathComponent(
      "\(invocation.invocationID.uuidString.lowercased()).json",
      isDirectory: false
    )
    guard FileManager.default.fileExists(atPath: url.path) == false else {
      throw EvaluationControllerError.staleInvocationExists
    }
    try EvaluationJSONFile.write(invocation, to: url)
    return WrittenInvocation(
      invocationID: invocation.invocationID,
      configurationSHA256: invocation.configurationSHA256,
      path: url.path
    )
  }

}
