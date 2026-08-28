import ClawAgent
import ClawCore
import ClawWorkspace
import Foundation

struct EvaluationRuntimeRunBudget: Codable, Sendable, Equatable {
  package let maxInputTokens: Int
  package let maxOutputTokens: Int
  package let maxTurns: Int
  package let maxToolCalls: Int
  package let deadlineSeconds: Int
  package let retryBudget: Int

  enum CodingKeys: String, CodingKey {
    case maxInputTokens = "max_input_tokens"
    case maxOutputTokens = "max_output_tokens"
    case maxTurns = "max_turns"
    case maxToolCalls = "max_tool_calls"
    case deadlineSeconds = "deadline_seconds"
    case retryBudget = "retry_budget"
  }
}

struct EvaluationRuntimeRetryPolicy: Codable, Sendable, Equatable {
  package let responsesSendsPerLogicalRoundTrip: Int
  package let maxResponsesSendsPerAttempt: Int
  package let providerInferenceRetryEnabled: Bool
  package let streamToBufferedReattemptEnabled: Bool
  package let wholeAttemptReplacementMax: Int

  enum CodingKeys: String, CodingKey {
    case responsesSendsPerLogicalRoundTrip = "responses_sends_per_logical_round_trip"
    case maxResponsesSendsPerAttempt = "max_responses_sends_per_attempt"
    case providerInferenceRetryEnabled = "provider_inference_retry_enabled"
    case streamToBufferedReattemptEnabled = "stream_to_buffered_reattempt_enabled"
    case wholeAttemptReplacementMax = "whole_attempt_replacement_max"
  }
}

struct EvaluationRuntimeFileReadAllowlists: Codable, Sendable, Equatable {
  let task: [String]
  let synthesis: [String]

  func expectedFileName(for stage: EvaluationPageStage) -> String? {
    switch stage {
    case .synthesis: synthesis.first
    case .canary, .development, .regression, .sealedPreRestart, .sealedPostRestart:
      task.first
    }
  }
}

package struct EvaluationRuntimeConfiguration: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let evaluationRoot: String
  let fixedTimestamp: String
  let providerReference: String
  let wireModel: String
  let transportMode: EvaluationTransportMode
  let fallbackReference: String?
  let expectedPolicyVersion: String
  let taskPromptPath: String
  let executablePath: String
  let freezeVerifierPath: String
  let toolCatalog: [String]
  let fileReadAllowlists: EvaluationRuntimeFileReadAllowlists
  let maxCompletedModelRoundTrips: Int
  let runBudget: EvaluationRuntimeRunBudget
  let inputMaxGraphemes: Int
  let attemptOutputLimits: AttemptOutputLimits
  let retry: EvaluationRuntimeRetryPolicy

  package static let exactKeys = Set(CodingKeys.allCases.map(\.rawValue))

  package static func load(from url: URL) throws -> Self {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    guard
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == exactKeys
    else {
      throw EvaluationRuntimeConfigurationError.invalidTopLevelKeys
    }
    let value = try JSONDecoder().decode(Self.self, from: data)
    try value.validate()
    return value
  }

  package var evaluationRootURL: URL {
    URL(fileURLWithPath: evaluationRoot, isDirectory: true)
  }

  package var workspaceRootURL: URL {
    evaluationRootURL.appendingPathComponent(PageEvaluationContract.workspaceDirectoryName)
  }

  package func validate() throws {
    let contract = EvaluationRuntimeContract.frozen
    guard
      schemaVersion == PageEvaluationContract.schemaVersion,
      evaluationRoot.hasPrefix("/"),
      ISO8601DateFormatter().date(from: fixedTimestamp) != nil,
      providerReference == contract.providerReference,
      wireModel == contract.wireModel,
      transportMode.rawValue == contract.transportMode,
      fallbackReference == nil,
      contract.isValidPolicyVersion(expectedPolicyVersion),
      Self.isSafeRepositoryRelativePath(taskPromptPath),
      Self.isSafeRepositoryRelativePath(executablePath),
      Self.isSafeRepositoryRelativePath(freezeVerifierPath),
      toolCatalog == [EvaluationToolContract.requiredToolName],
      fileReadAllowlists.task == [PageEvaluationContract.inputFileName],
      fileReadAllowlists.synthesis == [PageEvaluationContract.synthesisInputFileName],
      maxCompletedModelRoundTrips
        == contract.maximumCompletedModelRoundTripsPerAttempt,
      runBudget.maxInputTokens == contract.runBudget.maxInputTokens,
      runBudget.maxOutputTokens == contract.runBudget.maxOutputTokens,
      runBudget.maxTurns == contract.runBudget.maxTurns,
      runBudget.maxToolCalls == contract.runBudget.maxToolCalls,
      runBudget.deadlineSeconds == contract.runBudget.wallClockDeadlineSeconds,
      runBudget.retryBudget == contract.runBudget.retryBudget,
      inputMaxGraphemes == contract.maximumInputGraphemes,
      attemptOutputLimits == contract.outputLimits,
      retry.responsesSendsPerLogicalRoundTrip
        == contract.responsesSendsPerLogicalRoundTrip,
      retry.maxResponsesSendsPerAttempt == contract.maximumResponsesSendsPerAttempt,
      retry.providerInferenceRetryEnabled == false,
      retry.streamToBufferedReattemptEnabled == false,
      retry.wholeAttemptReplacementMax == contract.wholeAttemptReplacementMax
    else {
      throw EvaluationRuntimeConfigurationError.frozenValueMismatch
    }
    let productionRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(StateRootResolver.defaultDirectoryName)
      .resolvingSymlinksInPath()
    let root = evaluationRootURL.resolvingSymlinksInPath()
    guard EvaluationPathSecurity.isContainedOrEqual(root, under: productionRoot) == false else {
      throw EvaluationRuntimeConfigurationError.productionStateRootForbidden
    }
  }

  private static func isSafeRepositoryRelativePath(_ path: String) -> Bool {
    guard path.hasPrefix("/") == false else {
      return false
    }
    let components = URL(fileURLWithPath: path).pathComponents
    return path.isEmpty == false && components.contains("..") == false
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case evaluationRoot = "evaluation_root"
    case fixedTimestamp = "fixed_timestamp"
    case providerReference = "provider_reference"
    case wireModel = "wire_model"
    case transportMode = "transport_mode"
    case fallbackReference = "fallback_reference"
    case expectedPolicyVersion = "expected_policy_version"
    case taskPromptPath = "task_prompt_path"
    case executablePath = "executable_path"
    case freezeVerifierPath = "freeze_verifier_path"
    case toolCatalog = "tool_catalog"
    case fileReadAllowlists = "file_read_allowlists"
    case maxCompletedModelRoundTrips = "max_completed_model_round_trips"
    case runBudget = "run_budget"
    case inputMaxGraphemes = "input_max_graphemes"
    case attemptOutputLimits = "attempt_output_limits"
    case retry
  }
}

enum EvaluationRuntimeConfigurationError: Error, Sendable, Equatable {
  case invalidTopLevelKeys
  case frozenValueMismatch
  case productionStateRootForbidden
}

enum EvaluationRuntimeContextFactory {
  static func makeBuilder(
    workspaceRootURL: URL,
    providerReference: String,
    wireModel: String,
    toolDefinitions: [ToolDefinition],
    budget: ContextBudget,
    now: @escaping @Sendable () -> Date = Date.init
  ) -> ContextBuilder {
    let route = ResolvedLLMRoute(
      descriptor: .openAIChatGPT,
      configuredReference: providerReference,
      wireModel: wireModel
    )
    let staticSubhash = PolicyFingerprint.staticSubhash(
      inputs: PolicyFingerprint.StaticInputs(
        tools: toolDefinitions,
        llmEgress: route.descriptor.egress,
        searchEndpointPresent: false,
        workspaceRoot: workspaceRootURL.path,
        webFetchExemptCIDRs: [],
        exec: .disabledDefault
      )
    )
    return ContextBuilder(
      systemPrompt: SystemPrompt.minimal,
      proactiveSystemPrompt: SystemPrompt.proactive,
      workspace: FileSystemWorkspace(root: workspaceRootURL),
      memoryStore: EmptyMemoryStore(),
      retriever: EmptyRetriever(),
      budget: budget,
      fenceLabels: ToolFenceLabels(definitions: toolDefinitions),
      policyStaticSubhash: staticSubhash,
      now: now
    )
  }

  static func attemptBudget(toolDefinitions: [ToolDefinition]) -> ContextBudget {
    let contract = EvaluationRuntimeContract.frozen
    let messageInputTokens = TokenEstimator.messageInputBudget(
      maxInputTokens: contract.runBudget.maxInputTokens,
      tools: toolDefinitions
    )
    let defaults = ContextBudget.default
    return ContextBudget(
      inputCapGraphemes: TokenEstimator.graphemeBudget(forInputTokens: messageInputTokens),
      userFileCap: defaults.userFileCap,
      memoryFileCap: defaults.memoryFileCap,
      itemsCap: defaults.itemsCap,
      historyCap: defaults.historyCap,
      recallCap: defaults.recallCap,
      skillsCap: defaults.skillsCap,
      recallHitCap: defaults.recallHitCap
    )
  }
}

package enum EvaluationPolicyInspector {
  static func mismatch(
    for configuration: EvaluationAttemptConfiguration
  ) -> EvaluationAttemptError? {
    let observed = policyVersion(
      evaluationRootURL: configuration.evaluationRootURL,
      providerReference: configuration.providerReference,
      wireModel: configuration.wireModel,
      allowedFileName: configuration.expectedInputFileName
    )
    guard observed != configuration.expectedPolicyVersion else {
      return nil
    }
    return .policyMismatch(
      expected: configuration.expectedPolicyVersion,
      observed: observed
    )
  }

  package static func policyVersion(for configuration: EvaluationRuntimeConfiguration) -> String {
    policyVersion(
      evaluationRootURL: configuration.evaluationRootURL,
      providerReference: configuration.providerReference,
      wireModel: configuration.wireModel,
      allowedFileName: configuration.fileReadAllowlists.task[0]
    )
  }

  package static func policyVersion(
    evaluationRootURL: URL,
    providerReference: String = EvaluationRuntimeContract.frozen.providerReference,
    wireModel: String = EvaluationRuntimeContract.frozen.wireModel,
    allowedFileName: String = PageEvaluationContract.inputFileName
  ) -> String {
    let workspaceRootURL = evaluationRootURL.appendingPathComponent(
      PageEvaluationContract.workspaceDirectoryName
    )
    let recorder = EvaluationToolRecorder()
    let dispatcher = EvaluationToolDispatcher(
      workspaceRoot: workspaceRootURL,
      allowedFileName: allowedFileName,
      recorder: recorder
    )
    return EvaluationRuntimeContextFactory.makeBuilder(
      workspaceRootURL: workspaceRootURL,
      providerReference: providerReference,
      wireModel: wireModel,
      toolDefinitions: dispatcher.definitions,
      budget: .default,
    ).currentPolicyVersion()
  }
}
