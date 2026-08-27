import ClawCore
import Foundation

struct EvaluationApprovalBinding: Codable, Sendable, Equatable {
  package let commentID: Int64
  package let commentNodeID: String
  package let authorLogin: String
  package let authorID: Int64
  package let authorNodeID: String
  package let createdAt: String
  package let updatedAt: String
  package let manifestSHA256: String
  package let approvedManifestSHA256: String
  package let approvalCommentURL: String
  package let approvalBodySHA256: String

  package init(
    commentID: Int64,
    commentNodeID: String,
    authorLogin: String,
    authorID: Int64,
    authorNodeID: String,
    createdAt: String,
    updatedAt: String,
    manifestSHA256: String,
    approvedManifestSHA256: String,
    approvalCommentURL: String,
    approvalBodySHA256: String
  ) {
    self.commentID = commentID
    self.commentNodeID = commentNodeID
    self.authorLogin = authorLogin
    self.authorID = authorID
    self.authorNodeID = authorNodeID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.manifestSHA256 = manifestSHA256
    self.approvedManifestSHA256 = approvedManifestSHA256
    self.approvalCommentURL = approvalCommentURL
    self.approvalBodySHA256 = approvalBodySHA256
  }

  enum CodingKeys: String, CodingKey {
    case commentID = "comment_id"
    case commentNodeID = "comment_node_id"
    case authorLogin = "author_login"
    case authorID = "author_id"
    case authorNodeID = "author_node_id"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case manifestSHA256 = "manifest_sha256"
    case approvedManifestSHA256 = "approved_manifest_sha256"
    case approvalCommentURL = "approval_comment_url"
    case approvalBodySHA256 = "approval_body_sha256"
  }
}

struct EvaluationFrozenProvenance: Codable, Sendable, Equatable {
  package let freezeCommit: String
  package let executableSHA256: String
  package let runtimeSourcesSHA256: String
  package let harnessSourcesSHA256: String
  package let dependenciesSHA256: String
  package let configurationSHA256: String
  package let modelSHA256: String
  package let retrySHA256: String
  package let outputSHA256: String
  package let promptsSHA256: String
  package let schemasSHA256: String
  package let scorerSHA256: String
  package let splitsSHA256: String
  package let runOrderSHA256: String
  package let systemPromptSHA256: String
  package let proactiveSystemPromptSHA256: String

  package init(
    freezeCommit: String,
    executableSHA256: String,
    runtimeSourcesSHA256: String,
    harnessSourcesSHA256: String,
    dependenciesSHA256: String,
    configurationSHA256: String,
    modelSHA256: String,
    retrySHA256: String,
    outputSHA256: String,
    promptsSHA256: String,
    schemasSHA256: String,
    scorerSHA256: String,
    splitsSHA256: String,
    runOrderSHA256: String,
    systemPromptSHA256: String,
    proactiveSystemPromptSHA256: String
  ) {
    self.freezeCommit = freezeCommit
    self.executableSHA256 = executableSHA256
    self.runtimeSourcesSHA256 = runtimeSourcesSHA256
    self.harnessSourcesSHA256 = harnessSourcesSHA256
    self.dependenciesSHA256 = dependenciesSHA256
    self.configurationSHA256 = configurationSHA256
    self.modelSHA256 = modelSHA256
    self.retrySHA256 = retrySHA256
    self.outputSHA256 = outputSHA256
    self.promptsSHA256 = promptsSHA256
    self.schemasSHA256 = schemasSHA256
    self.scorerSHA256 = scorerSHA256
    self.splitsSHA256 = splitsSHA256
    self.runOrderSHA256 = runOrderSHA256
    self.systemPromptSHA256 = systemPromptSHA256
    self.proactiveSystemPromptSHA256 = proactiveSystemPromptSHA256
  }

  package var digests: [String] {
    [
      executableSHA256,
      runtimeSourcesSHA256,
      harnessSourcesSHA256,
      dependenciesSHA256,
      configurationSHA256,
      modelSHA256,
      retrySHA256,
      outputSHA256,
      promptsSHA256,
      schemasSHA256,
      scorerSHA256,
      splitsSHA256,
      runOrderSHA256,
      systemPromptSHA256,
      proactiveSystemPromptSHA256,
    ]
  }

  enum CodingKeys: String, CodingKey {
    case freezeCommit = "freeze_commit"
    case executableSHA256 = "executable_sha256"
    case runtimeSourcesSHA256 = "runtime_sources_sha256"
    case harnessSourcesSHA256 = "harness_sources_sha256"
    case dependenciesSHA256 = "dependencies_sha256"
    case configurationSHA256 = "configuration_sha256"
    case modelSHA256 = "model_sha256"
    case retrySHA256 = "retry_sha256"
    case outputSHA256 = "output_sha256"
    case promptsSHA256 = "prompts_sha256"
    case schemasSHA256 = "schemas_sha256"
    case scorerSHA256 = "scorer_sha256"
    case splitsSHA256 = "splits_sha256"
    case runOrderSHA256 = "run_order_sha256"
    case systemPromptSHA256 = "system_prompt_sha256"
    case proactiveSystemPromptSHA256 = "proactive_system_prompt_sha256"
  }
}

struct EvaluationAttemptConfiguration: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let attemptID: String
  package let fixtureID: String
  package let taskID: String
  package let split: String
  package let stage: String
  package let frozenOrderIndex: Int
  package let frozenOrderKey: String
  package let replicate: Int
  package let condition: EvaluationCondition
  package let evaluationRoot: String
  package let sourceArtifactPath: String
  package let sourceSHA256: String
  package let inputSHA256: String
  package let lessonSource: EvaluationLessonSource
  package let lessonArtifactPath: String?
  package let promotionReceiptPath: String?
  package let promotionReceiptSHA256: String?
  package let publishLessonAsActive: Bool
  package let taskPromptPath: String
  package let taskPromptSHA256: String
  package let resultPath: String
  package let fixedTimestamp: String
  package let protocolSHA256: String
  package let lessonSetDigest: String
  package let expectedPolicyVersion: String
  package let providerReference: String
  package let wireModel: String
  package let transportMode: EvaluationTransportMode
  package let fallbackReference: String?
  package let approval: EvaluationApprovalBinding
  package let provenance: EvaluationFrozenProvenance
  package let replacementOfAttemptID: String?
  package let replacementOrdinal: Int

  package init(
    schemaVersion: Int = PageEvaluationContract.schemaVersion,
    attemptID: String,
    fixtureID: String,
    taskID: String,
    split: String,
    stage: String,
    frozenOrderIndex: Int,
    frozenOrderKey: String,
    replicate: Int,
    condition: EvaluationCondition,
    evaluationRoot: String,
    sourceArtifactPath: String,
    sourceSHA256: String,
    inputSHA256: String,
    lessonSource: EvaluationLessonSource,
    lessonArtifactPath: String? = nil,
    promotionReceiptPath: String? = nil,
    promotionReceiptSHA256: String? = nil,
    publishLessonAsActive: Bool = false,
    taskPromptPath: String,
    taskPromptSHA256: String,
    resultPath: String,
    fixedTimestamp: String,
    protocolSHA256: String,
    lessonSetDigest: String,
    expectedPolicyVersion: String,
    providerReference: String = PageEvaluationContract.providerReference,
    wireModel: String = PageEvaluationContract.wireModel,
    transportMode: EvaluationTransportMode = .streamingSSE,
    fallbackReference: String? = nil,
    approval: EvaluationApprovalBinding,
    provenance: EvaluationFrozenProvenance,
    replacementOfAttemptID: String? = nil,
    replacementOrdinal: Int = 0
  ) {
    self.schemaVersion = schemaVersion
    self.attemptID = attemptID
    self.fixtureID = fixtureID
    self.taskID = taskID
    self.split = split
    self.stage = stage
    self.frozenOrderIndex = frozenOrderIndex
    self.frozenOrderKey = frozenOrderKey
    self.replicate = replicate
    self.condition = condition
    self.evaluationRoot = evaluationRoot
    self.sourceArtifactPath = sourceArtifactPath
    self.sourceSHA256 = sourceSHA256
    self.inputSHA256 = inputSHA256
    self.lessonSource = lessonSource
    self.lessonArtifactPath = lessonArtifactPath
    self.promotionReceiptPath = promotionReceiptPath
    self.promotionReceiptSHA256 = promotionReceiptSHA256
    self.publishLessonAsActive = publishLessonAsActive
    self.taskPromptPath = taskPromptPath
    self.taskPromptSHA256 = taskPromptSHA256
    self.resultPath = resultPath
    self.fixedTimestamp = fixedTimestamp
    self.protocolSHA256 = protocolSHA256
    self.lessonSetDigest = lessonSetDigest
    self.expectedPolicyVersion = expectedPolicyVersion
    self.providerReference = providerReference
    self.wireModel = wireModel
    self.transportMode = transportMode
    self.fallbackReference = fallbackReference
    self.approval = approval
    self.provenance = provenance
    self.replacementOfAttemptID = replacementOfAttemptID
    self.replacementOrdinal = replacementOrdinal
  }

  package var evaluationRootURL: URL {
    URL(fileURLWithPath: evaluationRoot, isDirectory: true)
  }

  package var stateRootURL: URL {
    evaluationRootURL.appendingPathComponent(PageEvaluationContract.stateDirectoryName)
  }

  package var workspaceRootURL: URL {
    evaluationRootURL.appendingPathComponent(PageEvaluationContract.workspaceDirectoryName)
  }

  var expectedInputFileName: String {
    stage == EvaluationPageStage.synthesis.rawValue
      ? PageEvaluationContract.synthesisInputFileName
      : PageEvaluationContract.inputFileName
  }

  package var resultURL: URL {
    URL(fileURLWithPath: resultPath)
  }

  package var requiresJointUnseal: Bool {
    EvaluationPageStage(rawValue: stage).map {
      $0 == .regression || $0.split == .sealed
    } ?? false
  }

  package var fixedDate: Date? {
    ISO8601DateFormatter().date(from: fixedTimestamp)
  }

  package func validate() throws {
    guard schemaVersion == PageEvaluationContract.schemaVersion else {
      throw EvaluationConfigurationError.unexpectedSchemaVersion(schemaVersion)
    }
    try validateAttemptIdentity()
    try validateProviderContract()
    try validatePaths()
    try validateDigests()
    try validateLessonSource()
    let pageStage = try validatedPageStage()
    try validateCondition(for: pageStage)
    try validateTopology(for: pageStage)
    try validateApprovalAndProvenance()
  }

  static let replacementLineageCodingKeys: Set<CodingKeys> = [
    .attemptID, .resultPath, .replacementOfAttemptID, .replacementOrdinal,
  ]

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case attemptID = "attempt_id"
    case fixtureID = "fixture_id"
    case taskID = "task_id"
    case split
    case stage
    case frozenOrderIndex = "frozen_order_index"
    case frozenOrderKey = "frozen_order_key"
    case replicate
    case condition
    case evaluationRoot = "evaluation_root"
    case sourceArtifactPath = "source_artifact_path"
    case sourceSHA256 = "source_sha256"
    case inputSHA256 = "input_sha256"
    case lessonSource = "lesson_source"
    case lessonArtifactPath = "lesson_artifact_path"
    case promotionReceiptPath = "promotion_receipt_path"
    case promotionReceiptSHA256 = "promotion_receipt_sha256"
    case publishLessonAsActive = "publish_lesson_as_active"
    case taskPromptPath = "task_prompt_path"
    case taskPromptSHA256 = "task_prompt_sha256"
    case resultPath = "result_path"
    case fixedTimestamp = "fixed_timestamp"
    case protocolSHA256 = "protocol_sha256"
    case lessonSetDigest = "lesson_set_digest"
    case expectedPolicyVersion = "expected_policy_version"
    case providerReference = "provider_reference"
    case wireModel = "wire_model"
    case transportMode = "transport_mode"
    case fallbackReference = "fallback_reference"
    case approval
    case provenance
    case replacementOfAttemptID = "replacement_of_attempt_id"
    case replacementOrdinal = "replacement_ordinal"
  }
}

// MARK: - Frozen Contract Validation

private extension EvaluationAttemptConfiguration {
  func validateAttemptIdentity() throws {
    guard
      attemptID.isEmpty == false,
      fixtureID.isEmpty == false,
      taskID.isEmpty == false,
      split.isEmpty == false,
      stage.isEmpty == false,
      frozenOrderIndex >= 0,
      (1...PageEvaluationContract.replicateCount).contains(replicate),
      replacementOrdinal >= 0,
      (replacementOrdinal == 0) == (replacementOfAttemptID == nil)
    else {
      throw EvaluationConfigurationError.invalidAttemptIdentity
    }
    guard Self.isOpaquePageTaskID(taskID) else {
      throw EvaluationConfigurationError.invalidTaskID(taskID)
    }
  }

  func validateProviderContract() throws {
    guard providerReference == PageEvaluationContract.providerReference else {
      throw EvaluationConfigurationError.unexpectedProviderReference(providerReference)
    }
    guard wireModel == PageEvaluationContract.wireModel else {
      throw EvaluationConfigurationError.unexpectedWireModel(wireModel)
    }
    guard transportMode.rawValue == PageEvaluationContract.transportMode else {
      throw EvaluationConfigurationError.unexpectedTransportMode(transportMode.rawValue)
    }
    guard fallbackReference == nil else {
      throw EvaluationConfigurationError.fallbackMustBeDisabled
    }
    guard fixedDate != nil else {
      throw EvaluationConfigurationError.invalidFixedTimestamp(fixedTimestamp)
    }
  }

  func validatePaths() throws {
    let absolutePaths =
      [evaluationRoot, sourceArtifactPath, taskPromptPath, resultPath]
      + optionalArtifactPaths
    guard absolutePaths.allSatisfy({ $0.hasPrefix("/") }) else {
      throw EvaluationConfigurationError.pathsMustBeAbsolute
    }
    let productionRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(StateRootResolver.defaultDirectoryName)
      .resolvingSymlinksInPath()
    guard
      EvaluationPathSecurity.isContainedOrEqual(
        evaluationRootURL.resolvingSymlinksInPath(),
        under: productionRoot
      ) == false
    else {
      throw EvaluationConfigurationError.productionStateRootForbidden
    }
    guard EvaluationPathSecurity.isStrictlyContained(resultURL, under: evaluationRootURL) else {
      throw EvaluationConfigurationError.resultOutsideEvaluationRoot(resultURL.path)
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [
        evaluationRootURL,
        stateRootURL,
        workspaceRootURL,
        URL(fileURLWithPath: sourceArtifactPath),
        URL(fileURLWithPath: taskPromptPath),
        resultURL.deletingLastPathComponent(),
        resultURL,
      ]
        + optionalArtifactPaths.map(URL.init(fileURLWithPath:))
    )
  }

  func validateDigests() throws {
    let digests =
      [
        frozenOrderKey,
        sourceSHA256,
        inputSHA256,
        taskPromptSHA256,
        protocolSHA256,
        lessonSetDigest,
        approval.manifestSHA256,
        approval.approvedManifestSHA256,
        approval.approvalBodySHA256,
      ] + [promotionReceiptSHA256].compactMap { $0 } + provenance.digests
    for digest in digests where Self.isSHA256(digest) == false {
      throw EvaluationConfigurationError.invalidSHA256(digest)
    }
  }

  func validateLessonSource() throws {
    switch lessonSource {
    case .clean:
      guard lessonArtifactPath == nil, publishLessonAsActive == false else {
        throw EvaluationConfigurationError.invalidLessonSource
      }
    case .artifact:
      guard lessonArtifactPath != nil else {
        throw EvaluationConfigurationError.invalidLessonSource
      }
    case .durableActive:
      guard lessonArtifactPath == nil, publishLessonAsActive == false else {
        throw EvaluationConfigurationError.invalidLessonSource
      }
    }
  }

  func validatedPageStage() throws -> EvaluationPageStage {
    guard
      let pageStage = EvaluationPageStage(rawValue: stage),
      let pageSplit = EvaluationPageSplit(rawValue: split),
      pageStage.split == pageSplit
    else {
      throw EvaluationConfigurationError.invalidStageTopology
    }
    return pageStage
  }

  func validateCondition(for pageStage: EvaluationPageStage) throws {
    switch condition {
    case .clean:
      guard
        lessonSource == .clean,
        promotionReceiptPath == nil,
        promotionReceiptSHA256 == nil
      else {
        throw EvaluationConfigurationError.invalidLessonSource
      }
    case .lessonConditioned:
      try validateConditionedLessonSource(.artifact, for: pageStage)
    case .postRestartLessonConditioned:
      try validateConditionedLessonSource(.durableActive, for: pageStage)
    case .synthesis, .canary:
      break
    }
  }

  func validateTopology(for pageStage: EvaluationPageStage) throws {
    switch pageStage {
    case .canary:
      guard condition == .canary, publishLessonAsActive == (lessonSource == .artifact) else {
        throw EvaluationConfigurationError.invalidStageTopology
      }
    case .development:
      guard isCleanWithoutPublication else {
        throw EvaluationConfigurationError.invalidStageTopology
      }
    case .regression:
      guard
        isCleanWithoutPublication || isLessonConditionedArtifact,
        publishLessonAsActive == false
      else {
        throw EvaluationConfigurationError.invalidStageTopology
      }
    case .sealedPreRestart:
      guard isCleanWithoutPublication || isLessonConditionedArtifact else {
        throw EvaluationConfigurationError.invalidStageTopology
      }
    case .sealedPostRestart:
      guard
        condition == .postRestartLessonConditioned,
        lessonSource == .durableActive,
        publishLessonAsActive == false
      else {
        throw EvaluationConfigurationError.invalidStageTopology
      }
    case .synthesis:
      guard condition == .synthesis, publishLessonAsActive == false else {
        throw EvaluationConfigurationError.invalidStageTopology
      }
    }
  }

  func validateApprovalAndProvenance() throws {
    guard approval.manifestSHA256 == approval.approvedManifestSHA256 else {
      throw EvaluationConfigurationError.manifestApprovalMismatch
    }
    guard Self.isApprovedIssueCommentURL(approval.approvalCommentURL) else {
      throw EvaluationConfigurationError.invalidApprovalURL
    }
    guard
      approval.commentID > 0,
      approval.commentNodeID.isEmpty == false,
      approval.authorLogin.isEmpty == false,
      approval.authorID > 0,
      approval.authorNodeID.isEmpty == false,
      approval.createdAt == approval.updatedAt,
      ISO8601DateFormatter().date(from: approval.createdAt) != nil,
      approval.approvalCommentURL.hasSuffix("issuecomment-\(approval.commentID)")
    else {
      throw EvaluationConfigurationError.invalidApprovalIdentity
    }
    guard Self.isGitCommit(provenance.freezeCommit) else {
      throw EvaluationConfigurationError.invalidFreezeCommit(provenance.freezeCommit)
    }
    guard PageEvaluationContract.isValidPolicyVersion(expectedPolicyVersion) else {
      throw EvaluationConfigurationError.invalidPolicyVersion(expectedPolicyVersion)
    }
  }

  func validateConditionedLessonSource(
    _ expectedLessonSource: EvaluationLessonSource,
    for pageStage: EvaluationPageStage
  ) throws {
    guard
      lessonSource == expectedLessonSource,
      pageStage == .canary || hasCompletePromotionReceipt
    else {
      throw EvaluationConfigurationError.invalidLessonSource
    }
  }

  var optionalArtifactPaths: [String] {
    [lessonArtifactPath, promotionReceiptPath].compactMap { $0 }
  }

  var hasCompletePromotionReceipt: Bool {
    promotionReceiptPath != nil && promotionReceiptSHA256 != nil
  }

  var isCleanWithoutPublication: Bool {
    condition == .clean && lessonSource == .clean && publishLessonAsActive == false
  }

  var isLessonConditionedArtifact: Bool {
    condition == .lessonConditioned && lessonSource == .artifact
  }
}

// MARK: - Frozen Value Validation

private extension EvaluationAttemptConfiguration {
  static func isSHA256(_ value: String) -> Bool {
    SHA256Digest.isCanonicalHex(value)
  }

  static func isLowerHex(_ character: Character) -> Bool {
    "0123456789abcdef".contains(character)
  }

  static func isGitCommit(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy(isLowerHex)
  }

  static func isOpaquePageTaskID(_ value: String) -> Bool {
    guard value.count == 17, value.hasPrefix("page-") else {
      return false
    }
    return value.dropFirst(5).allSatisfy(isLowerHex)
  }

  static func isApprovedIssueCommentURL(_ value: String) -> Bool {
    guard
      let components = URLComponents(string: value),
      components.scheme == "https",
      components.host == "github.com",
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.query == nil,
      components.path == "/ivan-magda/swift-claw/issues/118",
      let fragment = components.fragment,
      fragment.hasPrefix("issuecomment-"),
      fragment.dropFirst("issuecomment-".count).isEmpty == false,
      fragment.dropFirst("issuecomment-".count).allSatisfy(\.isNumber)
    else {
      return false
    }
    return true
  }
}

enum EvaluationConfigurationError: Error, Sendable, Equatable {
  case unexpectedSchemaVersion(Int)
  case invalidAttemptIdentity
  case invalidTaskID(String)
  case unexpectedProviderReference(String)
  case unexpectedWireModel(String)
  case unexpectedTransportMode(String)
  case fallbackMustBeDisabled
  case invalidFixedTimestamp(String)
  case pathsMustBeAbsolute
  case productionStateRootForbidden
  case resultOutsideEvaluationRoot(String)
  case invalidSHA256(String)
  case invalidLessonSource
  case invalidStageTopology
  case manifestApprovalMismatch
  case invalidApprovalURL
  case invalidApprovalIdentity
  case invalidFreezeCommit(String)
  case invalidPolicyVersion(String)
}
