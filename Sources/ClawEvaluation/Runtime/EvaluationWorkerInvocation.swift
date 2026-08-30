import ClawAgent
import ClawCore
import Foundation

package struct EvaluationSendBudgetSnapshot: Codable, Sendable, Equatable {
  package static let stageAccountedTokenCap = "evaluation-stage-accounted-token-threshold"
  package static let globalAccountedTokenCap = "evaluation-global-accounted-token-threshold"
  package static let stageResponsesSendCapName = "evaluation-stage-responses-send-cap"
  package static let globalResponsesSendCapName = "evaluation-global-responses-send-cap"

  package static func isControllerAdmissionCap(_ cap: String) -> Bool {
    [
      stageAccountedTokenCap,
      globalAccountedTokenCap,
      stageResponsesSendCapName,
      globalResponsesSendCapName,
    ].contains(cap)
  }

  package let stageAccountedTokens: Int
  package let globalAccountedTokens: Int
  package let stageResponsesSends: Int
  package let globalResponsesSends: Int
  package let stageAccountedTokenThreshold: Int
  package let globalAccountedTokenThreshold: Int
  package let stageResponsesSendCap: Int
  package let globalResponsesSendCap: Int

  package init(
    stageAccountedTokens: Int,
    globalAccountedTokens: Int,
    stageResponsesSends: Int,
    globalResponsesSends: Int,
    stageAccountedTokenThreshold: Int,
    globalAccountedTokenThreshold: Int = PageEvaluationContract.globalAccountedTokenThreshold,
    stageResponsesSendCap: Int,
    globalResponsesSendCap: Int = PageEvaluationContract.globalMaximumResponsesSends
  ) {
    self.stageAccountedTokens = stageAccountedTokens
    self.globalAccountedTokens = globalAccountedTokens
    self.stageResponsesSends = stageResponsesSends
    self.globalResponsesSends = globalResponsesSends
    self.stageAccountedTokenThreshold = stageAccountedTokenThreshold
    self.globalAccountedTokenThreshold = globalAccountedTokenThreshold
    self.stageResponsesSendCap = stageResponsesSendCap
    self.globalResponsesSendCap = globalResponsesSendCap
  }

  package func validate() throws {
    guard
      stageAccountedTokens >= 0,
      globalAccountedTokens >= 0,
      stageResponsesSends >= 0,
      globalResponsesSends >= 0,
      stageAccountedTokenThreshold > 0,
      globalAccountedTokenThreshold == PageEvaluationContract.globalAccountedTokenThreshold,
      stageResponsesSendCap > 0,
      globalResponsesSendCap == PageEvaluationContract.globalMaximumResponsesSends
    else {
      throw EvaluationWorkerInvocationError.invalidBudgetSnapshot
    }
  }

  package func validateScheduledLearning(
    approvedBudgets: EvaluationLearningApprovedBudgets
  ) throws {
    guard
      stageAccountedTokens >= 0,
      globalAccountedTokens >= 0,
      stageResponsesSends >= 0,
      globalResponsesSends >= 0,
      approvedBudgets.accountedTokens > 0,
      approvedBudgets.responsesSends > 0,
      stageAccountedTokenThreshold == approvedBudgets.accountedTokens,
      globalAccountedTokenThreshold == approvedBudgets.accountedTokens,
      stageResponsesSendCap == approvedBudgets.responsesSends,
      globalResponsesSendCap == approvedBudgets.responsesSends
    else {
      throw EvaluationWorkerInvocationError.invalidBudgetSnapshot
    }
  }

  package func admission(
    _ context: ProviderRoundTripAdmissionContext
  ) -> ProviderRoundTripAdmission {
    let reportedTokens = max(
      0,
      context.priorRecordedTokens - context.priorMissingUsageRecordedTokens
    )
    let missingUsageTokens = SaturatingArithmetic.product(
      context.priorMissingUsageResponsesSends,
      PageEvaluationContract.missingUsageTokenProxy
    )
    let priorAccountedTokens = SaturatingArithmetic.sum(reportedTokens, missingUsageTokens)
    let stageTokens = SaturatingArithmetic.sum(stageAccountedTokens, priorAccountedTokens)
    let globalTokens = SaturatingArithmetic.sum(globalAccountedTokens, priorAccountedTokens)
    let stageSends = SaturatingArithmetic.sum(stageResponsesSends, context.priorResponsesSends)
    let globalSends = SaturatingArithmetic.sum(globalResponsesSends, context.priorResponsesSends)
    if stageTokens >= stageAccountedTokenThreshold {
      return .deny(cap: Self.stageAccountedTokenCap)
    }
    if globalTokens >= globalAccountedTokenThreshold {
      return .deny(cap: Self.globalAccountedTokenCap)
    }
    if stageSends >= stageResponsesSendCap {
      return .deny(cap: Self.stageResponsesSendCapName)
    }
    if globalSends >= globalResponsesSendCap {
      return .deny(cap: Self.globalResponsesSendCapName)
    }
    return .allow
  }

  func advanced(by result: EvaluationAttemptResult) -> Self {
    Self(
      stageAccountedTokens: SaturatingArithmetic.sum(stageAccountedTokens, result.accountedTokens),
      globalAccountedTokens: SaturatingArithmetic.sum(
        globalAccountedTokens,
        result.accountedTokens
      ),
      stageResponsesSends: SaturatingArithmetic.sum(
        stageResponsesSends,
        result.http.responsesSends.count
      ),
      globalResponsesSends: SaturatingArithmetic.sum(
        globalResponsesSends,
        result.http.responsesSends.count
      ),
      stageAccountedTokenThreshold: stageAccountedTokenThreshold,
      globalAccountedTokenThreshold: globalAccountedTokenThreshold,
      stageResponsesSendCap: stageResponsesSendCap,
      globalResponsesSendCap: globalResponsesSendCap
    )
  }

  enum CodingKeys: String, CodingKey {
    case stageAccountedTokens = "stage_accounted_tokens"
    case globalAccountedTokens = "global_accounted_tokens"
    case stageResponsesSends = "stage_responses_sends"
    case globalResponsesSends = "global_responses_sends"
    case stageAccountedTokenThreshold = "stage_accounted_token_threshold"
    case globalAccountedTokenThreshold = "global_accounted_token_threshold"
    case stageResponsesSendCap = "stage_responses_send_cap"
    case globalResponsesSendCap = "global_responses_send_cap"
  }
}

package struct EvaluationWorkerInvocation: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let invocationID: UUID
  let kind: EvaluationWorkerInvocationKind
  let configurationPath: String
  let configurationSHA256: String
  let freeze: EvaluationFreezeInputs
  let budget: EvaluationSendBudgetSnapshot
  let authorization: EvaluationWorkerAuthorization

  init(
    schemaVersion: Int = PageEvaluationContract.schemaVersion,
    invocationID: UUID = UUID(),
    kind: EvaluationWorkerInvocationKind,
    configurationPath: String,
    configurationSHA256: String,
    freeze: EvaluationFreezeInputs,
    budget: EvaluationSendBudgetSnapshot,
    authorization: EvaluationWorkerAuthorization
  ) {
    self.schemaVersion = schemaVersion
    self.invocationID = invocationID
    self.kind = kind
    self.configurationPath = configurationPath
    self.configurationSHA256 = configurationSHA256
    self.freeze = freeze
    self.budget = budget
    self.authorization = authorization
  }

  func validate() throws {
    guard
      schemaVersion == PageEvaluationContract.schemaVersion,
      configurationPath.hasPrefix("/"),
      SHA256Digest.isCanonicalHex(configurationSHA256)
    else {
      throw EvaluationWorkerInvocationError.invalidInvocation
    }
    try budget.validate()
    try authorization.validate(
      invocationID: invocationID,
      invocationCoreSHA256: core.sha256
    )
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case invocationID = "invocation_id"
    case kind
    case configurationPath = "configuration_path"
    case configurationSHA256 = "configuration_sha256"
    case freeze
    case budget
    case authorization
  }

  var core: EvaluationWorkerInvocationCore {
    EvaluationWorkerInvocationCore(
      kind: kind,
      configurationPath: configurationPath,
      configurationSHA256: configurationSHA256,
      freeze: freeze,
      budget: budget
    )
  }
}

struct EvaluationWorkerInvocationCore: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let kind: EvaluationWorkerInvocationKind
  package let configurationPath: String
  package let configurationSHA256: String
  package let freeze: EvaluationFreezeInputs
  package let budget: EvaluationSendBudgetSnapshot

  package init(
    schemaVersion: Int = PageEvaluationContract.schemaVersion,
    kind: EvaluationWorkerInvocationKind,
    configurationPath: String,
    configurationSHA256: String,
    freeze: EvaluationFreezeInputs,
    budget: EvaluationSendBudgetSnapshot
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.configurationPath = configurationPath
    self.configurationSHA256 = configurationSHA256
    self.freeze = freeze
    self.budget = budget
  }

  package var sha256: String {
    guard let data = try? EvaluationCanonicalJSON.data(encoding: self) else {
      return ""
    }
    return SHA256Digest.hex(data)
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case kind
    case configurationPath = "configuration_path"
    case configurationSHA256 = "configuration_sha256"
    case freeze
    case budget
  }
}

/// Durable proof that the controller reserved this exact launch before exposing an invocation to a
/// call-capable worker. A package worker cannot silently bypass the controller's crash ledger: it
/// must find the byte-identical reservation in the manifest-bound append-only journal first.
struct EvaluationWorkerAuthorization: Codable, Sendable, Equatable {
  package let journalPath: String
  package let reservation: EvaluationControllerJournalEvent
  package let reservationSHA256: String

  package init(
    journalPath: String,
    reservation: EvaluationControllerJournalEvent,
    reservationSHA256: String
  ) {
    self.journalPath = journalPath
    self.reservation = reservation
    self.reservationSHA256 = reservationSHA256
  }

  package func validate(invocationID: UUID, invocationCoreSHA256: String) throws {
    guard
      journalPath.hasPrefix("/"),
      reservation.kind == .launchReserved,
      reservation.invocationID == invocationID,
      reservation.invocationCoreSHA256 == invocationCoreSHA256,
      reservation.attemptIDs.isEmpty == false,
      reservation.reservedResponsesSends > 0,
      reservation.reservedAccountedTokens > 0,
      reservation.observedResponsesSends == nil,
      reservation.observedAccountedTokens == nil,
      reservation.processID == nil,
      reservationSHA256 == SHA256Digest.hex(try EvaluationCanonicalJSON.data(encoding: reservation))
    else {
      throw EvaluationWorkerInvocationError.invalidAuthorization
    }
  }

  enum CodingKeys: String, CodingKey {
    case journalPath = "journal_path"
    case reservation
    case reservationSHA256 = "reservation_sha256"
  }
}

enum EvaluationWorkerInvocationKind: String, Codable, Sendable, Equatable {
  case attempt
  case canaryProcess = "canary_process"
}

/// A decode-once view of the exact configuration bytes bound by the controller reservation.
/// Canary authorization covers the batch file and both referenced attempt files so none of the
/// dynamic configuration closure can change between reservation and worker authorization.
struct EvaluationWorkerConfigurationSnapshot: Sendable {
  let attemptData: [Data]
  let sha256: String

  static func load(kind: EvaluationWorkerInvocationKind, path: String) throws -> Self {
    let primaryURL = try validatedURL(for: path)
    let primaryData = try EvaluationPathSecurity.readRegularSingleLinkFile(at: primaryURL)
    switch kind {
    case .attempt:
      return Self(
        attemptData: [primaryData],
        sha256: SHA256Digest.hex(primaryData)
      )
    case .canaryProcess:
      let batch = try JSONDecoder().decode(
        EvaluationWorkerBatchConfiguration.self,
        from: primaryData
      )
      guard
        batch.schemaVersion == PageEvaluationContract.schemaVersion,
        batch.attemptConfigurationPaths.count == PageEvaluationContract.canaryAttemptsPerProcess
      else {
        throw EvaluationWorkerInvocationError.invalidConfigurationSnapshot
      }
      var attemptData: [Data] = []
      var bindings: [[String: Any]] = []
      for path in batch.attemptConfigurationPaths {
        let url = try validatedURL(for: path)
        let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
        attemptData.append(data)
        bindings.append(["path": url.path, "sha256": SHA256Digest.hex(data)])
      }
      let closure = try EvaluationCanonicalJSON.data(fromJSONObject: [
        "attempts": bindings,
        "batch_path": primaryURL.path,
        "batch_sha256": SHA256Digest.hex(primaryData),
        "schema_version": PageEvaluationContract.schemaVersion,
      ])
      return Self(
        attemptData: attemptData,
        sha256: SHA256Digest.hex(closure)
      )
    }
  }

  private static func validatedURL(for path: String) throws -> URL {
    let rawURL = URL(fileURLWithPath: path)
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [rawURL.deletingLastPathComponent(), rawURL]
    )
    return rawURL.standardizedFileURL
  }

  func decodeAttempt() throws -> EvaluationAttemptConfiguration {
    guard attemptData.count == 1 else {
      throw EvaluationWorkerInvocationError.invalidConfigurationSnapshot
    }
    return try JSONDecoder().decode(EvaluationAttemptConfiguration.self, from: attemptData[0])
  }

  func decodeCanaryAttempts() throws -> [EvaluationAttemptConfiguration] {
    guard attemptData.count == PageEvaluationContract.canaryAttemptsPerProcess else {
      throw EvaluationWorkerInvocationError.invalidConfigurationSnapshot
    }
    return try attemptData.map {
      try JSONDecoder().decode(EvaluationAttemptConfiguration.self, from: $0)
    }
  }
}

enum EvaluationWorkerInvocationError: Error, Sendable, Equatable {
  case invalidInvocation
  case invalidBudgetSnapshot
  case invalidAuthorization
  case invalidConfigurationSnapshot
  case kindMismatch
}
