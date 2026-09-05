import ClawAgent
import ClawCore
import Foundation

package protocol EvaluationLearningAdmissionVerifying: Sendable {
  func verify(
    manifest: EvaluationLearningManifestBinding,
    authorization: EvaluationLearningOperationAuthorization,
    invocationCoreDigest: String,
    carrierSHA256: String,
    providerCallID: ProviderCallID,
    kind: EvaluationLearningOperationKind
  ) async throws -> EvaluationLearningAdmissionContext
}

package struct EvaluationLearningAdmissionContext: Sendable, Equatable {
  package let jobID: String
  package let operationID: String
  package let attemptGeneration: Int
  package let providerCallID: ProviderCallID
  package let manifestSHA256: String
  package let freezeCommit: String
  package let executableSHA256: String
  package let missingUsageTokenProxy: Int
  package let budgets: EvaluationLearningApprovedBudgets
  package let route: EvaluationLearningRouteBinding

  package init(
    jobID: String,
    operationID: String,
    attemptGeneration: Int,
    providerCallID: ProviderCallID,
    manifestSHA256: String,
    freezeCommit: String,
    executableSHA256: String,
    missingUsageTokenProxy: Int,
    budgets: EvaluationLearningApprovedBudgets,
    route: EvaluationLearningRouteBinding
  ) {
    self.jobID = jobID
    self.operationID = operationID
    self.attemptGeneration = attemptGeneration
    self.providerCallID = providerCallID
    self.manifestSHA256 = manifestSHA256
    self.freezeCommit = freezeCommit
    self.executableSHA256 = executableSHA256
    self.missingUsageTokenProxy = missingUsageTokenProxy
    self.budgets = budgets
    self.route = route
  }
}

package struct EvaluationLearningLiveAdmission: Sendable {
  package let verifier: any EvaluationLearningAdmissionVerifying
  package let manifest: EvaluationLearningManifestBinding
  package let authorization: EvaluationLearningOperationAuthorization
  package let invocationCoreDigest: String
  package let carrierSHA256: String
  package let providerCallID: ProviderCallID
  package let kind: EvaluationLearningOperationKind
  package let initial: EvaluationLearningAdmissionContext

  package init(
    verifier: any EvaluationLearningAdmissionVerifying,
    manifest: EvaluationLearningManifestBinding,
    authorization: EvaluationLearningOperationAuthorization,
    invocationCoreDigest: String,
    carrierSHA256: String,
    providerCallID: ProviderCallID,
    kind: EvaluationLearningOperationKind,
    initial: EvaluationLearningAdmissionContext
  ) {
    self.verifier = verifier
    self.manifest = manifest
    self.authorization = authorization
    self.invocationCoreDigest = invocationCoreDigest
    self.carrierSHA256 = carrierSHA256
    self.providerCallID = providerCallID
    self.kind = kind
    self.initial = initial
  }

  package func evaluate() async -> ProviderRoundTripAdmission {
    do {
      let refreshed = try await verifier.verify(
        manifest: manifest,
        authorization: authorization,
        invocationCoreDigest: invocationCoreDigest,
        carrierSHA256: carrierSHA256,
        providerCallID: providerCallID,
        kind: kind
      )
      return refreshed == initial ? .allow : .deny(cap: "evaluation-learning-integrity")
    } catch {
      return .deny(cap: "evaluation-learning-integrity")
    }
  }
}
