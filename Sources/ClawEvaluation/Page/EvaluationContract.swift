import ClawCore
import Foundation

/// Frozen runtime values shared by the page-change controller, worker, and manifest generator.
enum PageEvaluationContract {
  struct StageLimits: Sendable, Equatable {
    let maximumAttempts: Int
    let maximumResponsesSends: Int
    let maximumFileReads: Int
    let accountedTokenThreshold: Int
    let replacementPool: Int
  }

  package static let schemaVersion = 1
  package static let providerReference = "openai-chatgpt/gpt-5.6-sol"
  package static let wireModel = "gpt-5.6-sol"
  package static let transportMode = EvaluationTransportMode.streamingSSE.rawValue
  package static let inputFileName = "input.json"
  package static let synthesisInputFileName = "synthesis-input.json"
  package static let stateDirectoryName = "state"
  package static let workspaceDirectoryName = "workspace"
  package static let resultsDirectoryName = "results"
  package static let lessonSetsDirectoryName = "lesson-sets"
  package static let activeLessonFileName = "active.json"
  package static let policyVersionHexCount = 16
  package static let wholeAttemptReplacementMax = 1
  package static let maximumCompletedModelRoundTripsPerAttempt = 2
  package static let responsesSendsPerLogicalRoundTrip = 1
  package static let maximumResponsesSendsPerAttempt =
    maximumCompletedModelRoundTripsPerAttempt * responsesSendsPerLogicalRoundTrip
  package static let maximumInputGraphemes = 59_999
  package static let canaryProcessCount = 2
  package static let canaryAttemptsPerProcess = 2
  package static let canaryPlannedAttempts = canaryProcessCount * canaryAttemptsPerProcess
  package static let canaryEventCount = canaryPlannedAttempts + 1
  package static let canaryResponsesSendsPerProcess =
    canaryAttemptsPerProcess * maximumResponsesSendsPerAttempt
  package static let replicateCount = 3
  package static let developmentFixtureCount = 6
  package static let regressionFixtureCount = 3
  package static let sealedFixtureCount = 4
  package static let fixtureCount =
    developmentFixtureCount + regressionFixtureCount + sealedFixtureCount
  package static let pageDevelopmentPlannedAttempts = developmentFixtureCount * replicateCount
  package static let pageRegressionPlannedAttempts = regressionFixtureCount * replicateCount * 2
  package static let pageSealedPreRestartPlannedAttempts = sealedFixtureCount * replicateCount * 2
  package static let pageSealedPostRestartPlannedAttempts = sealedFixtureCount * replicateCount
  package static let pageUniqueBlockCount =
    pageDevelopmentPlannedAttempts + regressionFixtureCount * replicateCount
    + sealedFixtureCount * replicateCount
  package static let pageTaskPlannedAttempts =
    pageDevelopmentPlannedAttempts + pageRegressionPlannedAttempts
    + pageSealedPreRestartPlannedAttempts + pageSealedPostRestartPlannedAttempts
  package static let pageSynthesisPlannedAttempts = 1
  package static let pagePlannedAttempts = pageTaskPlannedAttempts + pageSynthesisPlannedAttempts
  package static let pageReplacementPool = 3
  package static let conformanceCaseCount = 24
  package static let missingUsageTokenProxy = 132_768
  package static let globalMaximumAttempts = 194
  package static let globalMaximumResponsesSends =
    globalMaximumAttempts * maximumResponsesSendsPerAttempt
  package static let globalMaximumFileReads = 194
  package static let globalAccountedTokenThreshold = 4_350_000
  package static let feedbackGeneratorVersion = "page-feedback-v1"
  package static let terminalValidationPolicy = StreamingTerminalValidationPolicy.throughStreamEnd
  static let canaryLimits = StageLimits(
    maximumAttempts: canaryPlannedAttempts,
    maximumResponsesSends: canaryPlannedAttempts * maximumResponsesSendsPerAttempt,
    maximumFileReads: canaryPlannedAttempts,
    accountedTokenThreshold: 50_000,
    replacementPool: 0
  )

  static let pageLimits = StageLimits(
    maximumAttempts: pagePlannedAttempts + pageReplacementPool,
    maximumResponsesSends: (pagePlannedAttempts + pageReplacementPool)
      * maximumResponsesSendsPerAttempt,
    maximumFileReads: pagePlannedAttempts + pageReplacementPool,
    accountedTokenThreshold: 1_500_000,
    replacementPool: pageReplacementPool
  )

  static var budgetManifestValues: JSONValue {
    .object([
      "canary_accounted_token_stopping_threshold": .integer(
        canaryLimits.accountedTokenThreshold
      ),
      "canary_attempt_cap": .integer(canaryLimits.maximumAttempts),
      "canary_responses_send_cap": .integer(canaryLimits.maximumResponsesSends),
      "global_accounted_token_stopping_threshold": .integer(globalAccountedTokenThreshold),
      "global_attempt_cap": .integer(globalMaximumAttempts),
      "global_file_read_cap": .integer(globalMaximumFileReads),
      "global_responses_send_cap": .integer(globalMaximumResponsesSends),
      "missing_usage_token_proxy": .integer(missingUsageTokenProxy),
      "page_accounted_token_stopping_threshold": .integer(pageLimits.accountedTokenThreshold),
      "page_attempt_cap": .integer(pageLimits.maximumAttempts),
      "page_planned_attempts": .integer(pagePlannedAttempts),
      "page_replacement_pool": .integer(pageLimits.replacementPool),
      "page_responses_send_cap": .integer(pageLimits.maximumResponsesSends),
    ])
  }

  package static let outputLimits = AttemptOutputLimits(
    maximumUTF8Bytes: 32_768,
    maximumGraphemes: 16_384
  )

  package static let runBudget = RunBudget(
    maxInputTokens: 100_000,
    maxOutputTokens: 4_096,
    wallClockDeadlineSeconds: 180,
    retryBudget: 1,
    perRunUSD: RunBudget.default.perRunUSD,
    perDayUSD: RunBudget.default.perDayUSD,
    proactivePerDayUSD: RunBudget.default.proactivePerDayUSD,
    referenceUSDPerToken: RunBudget.default.referenceUSDPerToken,
    maxTurns: 2,
    maxToolCalls: 1,
    dayTokenCeilingOverride: RunBudget.default.dayTokenCeiling
  )

  static func isValidPolicyVersion(_ value: String) -> Bool {
    value.count == policyVersionHexCount
      && value.allSatisfy { "0123456789abcdef".contains($0) }
  }
}

enum EvaluationTransportMode: String, Codable, Sendable, Equatable {
  case streamingSSE = "streaming_sse"
}

enum EvaluationCondition: String, Codable, Sendable, Equatable {
  case clean
  case lessonConditioned = "lesson_conditioned"
  case postRestartLessonConditioned = "post_restart_lesson_conditioned"
  case synthesis
  case canary

  var runOrderValue: String {
    switch self {
    case .clean: "clean"
    case .lessonConditioned: "lesson-conditioned"
    case .postRestartLessonConditioned: "post-restart lesson-conditioned"
    case .synthesis: "synthesis"
    case .canary: "canary"
    }
  }

  init?(runOrderValue: String) {
    switch runOrderValue {
    case "clean": self = .clean
    case "lesson-conditioned": self = .lessonConditioned
    case "post-restart lesson-conditioned": self = .postRestartLessonConditioned
    case "synthesis": self = .synthesis
    case "canary": self = .canary
    default: return nil
    }
  }
}

enum EvaluationLessonSource: String, Codable, Sendable, Equatable {
  case clean
  case artifact
  case durableActive = "durable_active"
}
