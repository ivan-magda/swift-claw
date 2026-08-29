import ClawCore
import Foundation

/// Frozen fixture, topology, and stage-budget values owned by the page-change experiment.
enum PageEvaluationContract {
  static let profile = EvaluationExperimentProfile.pageChange
  static let runtime = profile.runtime

  struct StageLimits: Sendable, Equatable {
    let maximumAttempts: Int
    let maximumResponsesSends: Int
    let maximumFileReads: Int
    let accountedTokenThreshold: Int
    let replacementPool: Int
  }

  struct RecoveryUsage: Sendable, Equatable {
    let attempts: Int
    let responsesSends: Int
    let fileReads: Int
    let accountedTokens: Int

    var manifestValue: JSONValue {
      .object([
        "accounted_tokens": .integer(accountedTokens),
        "attempts": .integer(attempts),
        "file_reads": .integer(fileReads),
        "responses_sends": .integer(responsesSends),
      ])
    }
  }

  struct RecoveryAccountingSeed: Sendable, Equatable {
    let canary: RecoveryUsage
    let pageCleanDevelopment: RecoveryUsage

    var total: RecoveryUsage {
      RecoveryUsage(
        attempts: canary.attempts + pageCleanDevelopment.attempts,
        responsesSends: canary.responsesSends + pageCleanDevelopment.responsesSends,
        fileReads: canary.fileReads + pageCleanDevelopment.fileReads,
        accountedTokens: canary.accountedTokens + pageCleanDevelopment.accountedTokens
      )
    }

    var manifestValue: JSONValue {
      .object([
        "canary": canary.manifestValue,
        "page_clean_development": pageCleanDevelopment.manifestValue,
        "total": total.manifestValue,
      ])
    }
  }

  package static let schemaVersion = 1
  package static let providerReference = runtime.providerReference
  package static let wireModel = runtime.wireModel
  package static let transportMode = runtime.transportMode
  package static let inputFileName = "input.json"
  package static let synthesisInputFileName = "synthesis-input.json"
  package static let stateDirectoryName = "state"
  package static let workspaceDirectoryName = "workspace"
  package static let resultsDirectoryName = "results"
  package static let lessonSetsDirectoryName = "lesson-sets"
  package static let activeLessonFileName = "active.json"
  package static let wholeAttemptReplacementMax = runtime.wholeAttemptReplacementMax
  // swiftlint:disable:next identifier_name
  package static let maximumCompletedModelRoundTripsPerAttempt =
    runtime.maximumCompletedModelRoundTripsPerAttempt
  package static let responsesSendsPerLogicalRoundTrip =
    runtime.responsesSendsPerLogicalRoundTrip
  package static let maximumResponsesSendsPerAttempt = runtime.maximumResponsesSendsPerAttempt
  package static let maximumInputGraphemes = runtime.maximumInputGraphemes
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
  package static let missingUsageTokenProxy = runtime.missingUsageTokenProxy
  package static let globalMaximumAttempts = runtime.globalMaximumAttempts
  package static let globalMaximumResponsesSends = runtime.globalMaximumResponsesSends
  package static let globalMaximumFileReads = runtime.globalMaximumFileReads
  package static let globalAccountedTokenThreshold = runtime.globalAccountedTokenThreshold
  static let recoveryAccountingSeed = RecoveryAccountingSeed(
    canary: RecoveryUsage(
      attempts: 8,
      responsesSends: 16,
      fileReads: 8,
      accountedTokens: 19_098
    ),
    pageCleanDevelopment: RecoveryUsage(
      attempts: 26,
      responsesSends: 50,
      fileReads: 25,
      accountedTokens: 66_859
    )
  )
  package static let feedbackGeneratorVersion = "page-feedback-v1"
  package static let targetClasses = Set([
    "noise.volatile_value",
    "noise.time_or_build_metadata",
    "noise.structure_or_order",
  ])
  package static let terminalValidationPolicy = runtime.terminalValidationPolicy
  static let canaryLimits = StageLimits(
    maximumAttempts: recoveryAccountingSeed.canary.attempts + canaryPlannedAttempts,
    maximumResponsesSends: recoveryAccountingSeed.canary.responsesSends
      + canaryPlannedAttempts * maximumResponsesSendsPerAttempt,
    maximumFileReads: recoveryAccountingSeed.canary.fileReads + canaryPlannedAttempts,
    accountedTokenThreshold: 50_000,
    replacementPool: 0
  )

  static let pageLimits = StageLimits(
    maximumAttempts: recoveryAccountingSeed.pageCleanDevelopment.attempts + pagePlannedAttempts
      + pageReplacementPool,
    maximumResponsesSends: recoveryAccountingSeed.pageCleanDevelopment.responsesSends
      + (pagePlannedAttempts + pageReplacementPool)
        * maximumResponsesSendsPerAttempt,
    maximumFileReads: recoveryAccountingSeed.pageCleanDevelopment.fileReads + pagePlannedAttempts
      + pageReplacementPool,
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
      "recovery_accounting_seed": recoveryAccountingSeed.manifestValue,
    ])
  }

  package static let outputLimits = runtime.outputLimits

  package static let runBudget = runtime.runBudget

  static func isValidPolicyVersion(_ value: String) -> Bool {
    runtime.isValidPolicyVersion(value)
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

package enum EvaluationLessonSource: String, Codable, Sendable, Equatable {
  case clean
  case artifact
  case durableActive = "durable_active"
}
