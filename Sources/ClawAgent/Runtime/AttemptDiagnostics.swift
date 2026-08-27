import ClawCore

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
