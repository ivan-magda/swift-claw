import ClawCore

package enum EvaluationExperimentKind: String, Sendable {
  case pageChange = "page-change"
  case dependencyPrioritization = "dependency-prioritization"

  package var profile: EvaluationExperimentProfile {
    switch self {
    case .pageChange:
      .pageChange
    case .dependencyPrioritization:
      .dependencyPrioritization
    }
  }
}

package struct EvaluationExperimentProfile: Sendable, Equatable {
  package static let pageChange = Self(kind: .pageChange, approvalDecision: "D6")
  package static let dependencyPrioritization = Self(
    kind: .dependencyPrioritization,
    approvalDecision: "D7"
  )

  package let kind: EvaluationExperimentKind
  package let approvalDecision: String
  package let runtime: EvaluationRuntimeContract

  private init(kind: EvaluationExperimentKind, approvalDecision: String) {
    self.kind = kind
    self.approvalDecision = approvalDecision
    runtime = .frozen
  }

  package static func matching(decision: String?, experiment: String?) -> Self? {
    guard let experiment, let kind = EvaluationExperimentKind(rawValue: experiment) else {
      return nil
    }
    let profile = kind.profile
    guard decision == profile.approvalDecision else {
      return nil
    }
    return profile
  }

  package func matches(decision: String?, experiment: String?) -> Bool {
    Self.matching(decision: decision, experiment: experiment) == self
  }
}

package struct EvaluationRuntimeContract: Sendable, Equatable {
  package static let frozen = Self()

  package let providerReference = "openai-chatgpt/gpt-5.6-sol"
  package let wireModel = "gpt-5.6-sol"
  package let transportMode = EvaluationTransportMode.streamingSSE.rawValue
  package let wholeAttemptReplacementMax = 1
  // swiftlint:disable:next identifier_name
  package let maximumCompletedModelRoundTripsPerAttempt = 2
  package let responsesSendsPerLogicalRoundTrip = 1
  package let maximumInputGraphemes = 59_999
  package let missingUsageTokenProxy = 132_768
  package let globalMaximumAttempts = 228
  package let globalMaximumResponsesSends = 454
  package let globalMaximumFileReads = 227
  package let globalAccountedTokenThreshold = 4_350_000
  package let policyVersionHexCount = 16
  package let terminalValidationPolicy = StreamingTerminalValidationPolicy.throughStreamEnd
  package let outputLimits = AttemptOutputLimits(
    maximumUTF8Bytes: 32_768,
    maximumGraphemes: 16_384
  )
  package let runBudget = RunBudget(
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

  package var maximumResponsesSendsPerAttempt: Int {
    maximumCompletedModelRoundTripsPerAttempt * responsesSendsPerLogicalRoundTrip
  }

  package func isValidPolicyVersion(_ value: String) -> Bool {
    value.count == policyVersionHexCount
      && value.allSatisfy { "0123456789abcdef".contains($0) }
  }
}
