import ClawCore

/// Whether a clean streaming connect/head failure may be sent again through `complete`.
package enum StreamingReattemptPolicy: Sendable, Equatable {
  case bufferedWhenSafe
  case disabled
}

package struct ModelRoundTripObservation: Codable, Sendable, Equatable {
  package let outboundModel: String
  package let terminalModel: String?

  package init(outboundModel: String, terminalModel: String?) {
    self.outboundModel = outboundModel
    self.terminalModel = terminalModel
  }

  enum CodingKeys: String, CodingKey {
    case outboundModel = "outbound_model"
    case terminalModel = "terminal_model"
  }
}

package struct ProviderRoundTripAdmissionContext: Sendable, Equatable {
  package let roundTripIndex: Int
  package let priorRecordedTokens: Int
  package let priorResponsesSends: Int
  package let priorMissingUsageRecordedTokens: Int
  package let priorMissingUsageResponsesSends: Int

  package init(
    roundTripIndex: Int,
    priorRecordedTokens: Int,
    priorResponsesSends: Int,
    priorMissingUsageRecordedTokens: Int = 0,
    priorMissingUsageResponsesSends: Int = 0
  ) {
    self.roundTripIndex = roundTripIndex
    self.priorRecordedTokens = priorRecordedTokens
    self.priorResponsesSends = priorResponsesSends
    self.priorMissingUsageRecordedTokens = priorMissingUsageRecordedTokens
    self.priorMissingUsageResponsesSends = priorMissingUsageResponsesSends
  }
}

package typealias ProviderRoundTripAdmission = BudgetDecision

/// Payload-free attempt failure causes that a package caller may interpret under its own policy.
/// This is descriptive only: it grants no retry or replacement eligibility.
package enum AttemptFailureCause: CaseIterable, Sendable, Equatable {
  case transportFailure
  case credentialRefreshCompleted
  case credentialRefreshExhausted
  case credentialStateUnavailable
  case deadline
  case processInterruption
  case partialStreamWithoutCompletedTerminal
  case localOutputLimit
  case modelIdentityMismatch
}

package struct AttemptDiagnostics: Sendable, Equatable {
  package let outputCounts: AttemptOutputCounts?
  package let modelObservations: [ModelRoundTripObservation]
  package let failureCause: AttemptFailureCause?

  package init(
    outputCounts: AttemptOutputCounts?,
    modelObservations: [ModelRoundTripObservation],
    failureCause: AttemptFailureCause?
  ) {
    self.outputCounts = outputCounts
    self.modelObservations = modelObservations
    self.failureCause = failureCause
  }

  package static let empty = Self(
    outputCounts: nil,
    modelObservations: [],
    failureCause: nil
  )
}

/// Optional attempt-level controls used by package compositions and tests. The public runtime always
/// receives `production`, keeping caller-specific policy out of the product API and gateway.
package struct AttemptRuntimePolicy: Sendable {
  package let streamingReattemptPolicy: StreamingReattemptPolicy
  package let terminalValidationPolicy: StreamingTerminalValidationPolicy
  package let outputLimits: AttemptOutputLimits?
  package let expectedWireModel: String?
  package let roundTripAdmission:
    (@Sendable (ProviderRoundTripAdmissionContext) async -> ProviderRoundTripAdmission)?

  package init(
    streamingReattemptPolicy: StreamingReattemptPolicy = .bufferedWhenSafe,
    terminalValidationPolicy: StreamingTerminalValidationPolicy = .firstTerminal,
    outputLimits: AttemptOutputLimits? = nil,
    expectedWireModel: String? = nil,
    roundTripAdmission:
      (@Sendable (ProviderRoundTripAdmissionContext) async -> ProviderRoundTripAdmission)? = nil
  ) {
    self.streamingReattemptPolicy = streamingReattemptPolicy
    self.terminalValidationPolicy = terminalValidationPolicy
    self.outputLimits = outputLimits
    self.expectedWireModel = expectedWireModel
    self.roundTripAdmission = roundTripAdmission
  }

  package static let production = Self()
}

struct AttemptRuntimeState {
  private let policy: AttemptRuntimePolicy
  private let outputLimiter: AttemptOutputLimiter?
  private var modelObservations: [ModelRoundTripObservation] = []
  private var missingUsageRecordedTokens = 0
  private var missingUsageResponsesSends = 0

  init(policy: AttemptRuntimePolicy) {
    self.policy = policy
    outputLimiter = policy.outputLimits.map(AttemptOutputLimiter.init(limits:))
  }

  var terminalValidationPolicy: StreamingTerminalValidationPolicy {
    policy.terminalValidationPolicy
  }

  mutating func beginRound(outboundModel: String) -> AttemptOutputScope? {
    modelObservations.append(
      ModelRoundTripObservation(outboundModel: outboundModel, terminalModel: nil)
    )
    return outputLimiter?.beginRound()
  }

  func accepts(outboundModel: String) -> Bool {
    policy.expectedWireModel.map { $0 == outboundModel } ?? true
  }

  mutating func observe(response: ChatResponse, outboundModel: String) -> Bool {
    modelObservations[modelObservations.count - 1] = ModelRoundTripObservation(
      outboundModel: outboundModel,
      terminalModel: response.reportedModel
    )
    return policy.expectedWireModel.flatMap { expected in
      response.reportedModel.map { $0 != expected }
    } ?? false
  }

  func finalize(_ response: ChatResponse, scope: AttemptOutputScope?) throws {
    try scope?.finalize(response)
  }

  func admission(
    roundTripIndex: Int,
    priorRecordedTokens: Int,
    priorResponsesSends: Int
  ) async -> ProviderRoundTripAdmission? {
    guard let admission = policy.roundTripAdmission else { return nil }
    return await admission(
      ProviderRoundTripAdmissionContext(
        roundTripIndex: roundTripIndex,
        priorRecordedTokens: priorRecordedTokens,
        priorResponsesSends: priorResponsesSends,
        priorMissingUsageRecordedTokens: missingUsageRecordedTokens,
        priorMissingUsageResponsesSends: missingUsageResponsesSends
      )
    )
  }

  mutating func recordMissingUsage(_ usage: ProviderUsage) {
    missingUsageRecordedTokens = SaturatingArithmetic.sum(
      missingUsageRecordedTokens,
      SaturatingArithmetic.sum(usage.promptTokens, usage.completionTokens)
    )
    missingUsageResponsesSends += 1
  }

  func diagnostics(failureCause: AttemptFailureCause?) -> AttemptDiagnostics {
    AttemptDiagnostics(
      outputCounts: outputLimiter?.counts,
      modelObservations: modelObservations,
      failureCause: failureCause
    )
  }
}
