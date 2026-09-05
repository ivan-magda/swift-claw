import ClawAgent
import ClawCore
import Foundation

extension EvaluationAttemptRunner {
  static func verifiedTaskPrompt(
    configuration: EvaluationAttemptConfiguration
  ) throws -> String {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(
      at: URL(fileURLWithPath: configuration.taskPromptPath)
    )
    let observed = SHA256Digest.hex(data)
    guard observed == configuration.taskPromptSHA256 else {
      throw EvaluationAttemptError.taskPromptDigestMismatch(
        expected: configuration.taskPromptSHA256,
        observed: observed
      )
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw EvaluationAttemptError.taskPromptIsNotUTF8
    }
    return text
  }

  static func validate(
    roster: ProviderRoster,
    configuration: EvaluationAttemptConfiguration
  ) throws {
    guard roster.fallback == nil else {
      throw EvaluationAttemptError.fallbackRosterForbidden
    }
    let primary = roster.primary
    guard primary.configuredReference == configuration.providerReference else {
      throw EvaluationAttemptError.rosterProviderReferenceMismatch
    }
    guard primary.wireModel == configuration.wireModel else {
      throw EvaluationAttemptError.rosterWireModelMismatch
    }
    guard primary.costPolicy == .includedPlan else {
      throw EvaluationAttemptError.rosterCostPolicyMismatch
    }
    guard primary.reservationPolicy == .chatGPTReplayState else {
      throw EvaluationAttemptError.rosterReservationPolicyMismatch
    }
  }

  static func validateProductionPrompts(_ provenance: EvaluationFrozenProvenance) throws {
    let systemDigest = SHA256Digest.hex(Data(SystemPrompt.minimal.utf8))
    let proactiveDigest = SHA256Digest.hex(Data(SystemPrompt.proactive.utf8))
    guard systemDigest == provenance.systemPromptSHA256 else {
      throw EvaluationAttemptError.systemPromptDigestMismatch
    }
    guard proactiveDigest == provenance.proactiveSystemPromptSHA256 else {
      throw EvaluationAttemptError.proactiveSystemPromptDigestMismatch
    }
  }

  // swiftlint:disable:next function_body_length function_parameter_count
  static func buildContext(
    configuration: EvaluationAttemptConfiguration,
    taskPrompt: String,
    sessionID: Int64,
    dispatcher: EvaluationToolDispatcher,
    memoryStore: any MemoryStore,
    learningMaterialization: EvaluationLearningTaskMaterialization?,
    initialTainted: Bool
  ) throws -> BuildResult {
    guard let fixedDate = configuration.fixedDate else {
      throw EvaluationConfigurationError.invalidFixedTimestamp(configuration.fixedTimestamp)
    }
    let fullBudget = EvaluationRuntimeContextFactory.attemptBudget(
      toolDefinitions: dispatcher.definitions
    )
    let lessonMessage = learningMaterialization.map { materialization in
      ChatMessage(
        role: .user,
        content: LabeledContextFactory.make(
          label: "scheduled_learning_lessons",
          content: materialization.lessonSetText
        ).render()
      )
    }
    let reservedInputGraphemes = lessonMessage?.content.text.count ?? 0
    guard reservedInputGraphemes <= fullBudget.inputCapGraphemes else {
      throw EvaluationAttemptError.requiredLessonContextExceedsBudget
    }
    let fittedBudget = EvaluationRuntimeContextFactory.attemptBudget(
      toolDefinitions: dispatcher.definitions,
      reservedInputGraphemes: reservedInputGraphemes
    )
    let builder = EvaluationRuntimeContextFactory.makeBuilder(
      workspaceRootURL: configuration.workspaceRootURL,
      providerReference: configuration.providerReference,
      wireModel: configuration.wireModel,
      toolDefinitions: dispatcher.definitions,
      budget: fittedBudget,
      memoryStore: memoryStore,
      now: { fixedDate }
    )
    let snapshot = SessionContextSnapshot(
      sessionKey: "session:\(configuration.attemptID)",
      history: [
        StoredMessage(
          role: .user,
          content: taskPrompt,
          provenance: .trusted
        )
      ],
      historyMessageIds: [1],
      windowStartMessageId: nil,
      isTainted: initialTainted,
      hasPrivateData: false
    )
    let buildResult = try builder.assemble(
      snapshot: snapshot,
      sessionId: sessionID,
      origin: .scheduled
    )
    guard let lessonMessage else {
      return buildResult
    }
    var learningMessages = buildResult.messages
    learningMessages.insert(
      lessonMessage,
      at: learningMessages.index(before: learningMessages.endIndex)
    )
    return BuildResult(
      messages: learningMessages,
      ownerNotices: buildResult.ownerNotices,
      hasPrivateDataAccess: buildResult.hasPrivateDataAccess,
      policyVersion: buildResult.policyVersion
    )
  }
}

enum EvaluationAttemptError: Error, Sendable, Equatable {
  case taskPromptDigestMismatch(expected: String, observed: String)
  case taskPromptIsNotUTF8
  case policyMismatch(expected: String, observed: String)
  case fallbackRosterForbidden
  case rosterProviderReferenceMismatch
  case rosterWireModelMismatch
  case rosterCostPolicyMismatch
  case rosterReservationPolicyMismatch
  case systemPromptDigestMismatch
  case proactiveSystemPromptDigestMismatch
  case requiredLessonContextExceedsBudget
}
