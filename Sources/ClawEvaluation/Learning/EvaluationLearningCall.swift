import ClawCore
import Foundation

// swiftlint:disable file_length

package struct EvaluationLearningCallRequest: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let executionProfile: EvaluationLearningExecutionProfile
  package let jobID: String
  package let operationID: String
  package let attemptGeneration: Int
  package let providerCallID: ProviderCallID
  package let kind: EvaluationLearningOperationKind
  package let stateRoot: String
  package let prompt: EvaluationLearningArtifactBinding
  package let carrier: EvaluationLearningArtifactBinding
  package let resultPath: String
  package let manifest: EvaluationLearningManifestBinding
  package let authorization: EvaluationLearningOperationAuthorization

  package init(
    schemaVersion: Int = 1,
    executionProfile: EvaluationLearningExecutionProfile,
    jobID: String,
    operationID: String,
    attemptGeneration: Int,
    providerCallID: ProviderCallID,
    kind: EvaluationLearningOperationKind,
    stateRoot: String,
    prompt: EvaluationLearningArtifactBinding,
    carrier: EvaluationLearningArtifactBinding,
    resultPath: String,
    manifest: EvaluationLearningManifestBinding,
    authorization: EvaluationLearningOperationAuthorization
  ) {
    self.schemaVersion = schemaVersion
    self.executionProfile = executionProfile
    self.jobID = jobID
    self.operationID = operationID
    self.attemptGeneration = attemptGeneration
    self.providerCallID = providerCallID
    self.kind = kind
    self.stateRoot = stateRoot
    self.prompt = prompt
    self.carrier = carrier
    self.resultPath = resultPath
    self.manifest = manifest
    self.authorization = authorization
  }

  package var core: EvaluationLearningCallRequestCore {
    EvaluationLearningCallRequestCore(
      schemaVersion: schemaVersion,
      executionProfile: executionProfile,
      jobID: jobID,
      operationID: operationID,
      attemptGeneration: attemptGeneration,
      providerCallID: providerCallID,
      kind: kind,
      stateRoot: stateRoot,
      prompt: prompt,
      carrier: carrier,
      resultPath: resultPath,
      manifest: manifest
    )
  }

  package static func load(from url: URL) throws -> Self {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    let object = try EvaluationLearningClosedJSON.object(from: data)
    try requireExactKeys(object, keys: Set(CodingKeys.allCases.map(\.rawValue)))
    try requireExactObjectKeys(
      in: object,
      path: [CodingKeys.prompt.rawValue],
      keys: ["path", "sha256"]
    )
    try requireExactObjectKeys(
      in: object,
      path: [CodingKeys.carrier.rawValue],
      keys: ["path", "sha256"]
    )
    try requireExactObjectKeys(
      in: object,
      path: [CodingKeys.manifest.rawValue],
      keys: [
        "repository_root", "evaluation_root", "manifest_path", "manifest_sha256",
        "owner_approval",
      ]
    )
    try requireExactObjectKeys(
      in: object,
      path: [CodingKeys.manifest.rawValue, "owner_approval"],
      keys: ["path", "sha256"]
    )
    try requireExactObjectKeys(
      in: object,
      path: [CodingKeys.authorization.rawValue],
      keys: ["event_path", "event_sha256"]
    )
    let request = try EvaluationLearningClosedJSON.decode(
      Self.self,
      from: data,
      object: object
    )
    try request.validate()
    return request
  }

  package func validate() throws {
    guard
      schemaVersion == 1,
      executionProfile == .scheduledLearningV1,
      kind == .evaluator || kind == .reflector,
      jobID.isEmpty == false,
      operationID.isEmpty == false,
      attemptGeneration > 0,
      Self.isCanonical(providerCallID),
      SHA256Digest.isCanonicalHex(prompt.sha256),
      SHA256Digest.isCanonicalHex(carrier.sha256),
      SHA256Digest.isCanonicalHex(manifest.manifestSHA256),
      SHA256Digest.isCanonicalHex(manifest.ownerApproval.sha256),
      SHA256Digest.isCanonicalHex(authorization.eventSHA256)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }

    let repository = try Self.absoluteURL(manifest.repositoryRoot)
    let evaluation = try Self.absoluteURL(manifest.evaluationRoot)
    let state = try Self.absoluteURL(stateRoot)
    let promptURL = try Self.absoluteURL(prompt.path)
    let carrierURL = try Self.absoluteURL(carrier.path)
    let resultURL = try Self.absoluteURL(resultPath)
    let manifestURL = try Self.absoluteURL(manifest.manifestPath)
    let approvalURL = try Self.absoluteURL(manifest.ownerApproval.path)
    let eventURL = try Self.absoluteURL(authorization.eventPath)
    guard
      EvaluationPathSecurity.isStrictlyContained(evaluation, under: repository),
      EvaluationPathSecurity.isStrictlyContained(state, under: evaluation),
      EvaluationPathSecurity.isStrictlyContained(promptURL, under: repository),
      EvaluationPathSecurity.isStrictlyContained(carrierURL, under: evaluation),
      EvaluationPathSecurity.isStrictlyContained(resultURL, under: state),
      EvaluationPathSecurity.isStrictlyContained(manifestURL, under: repository),
      EvaluationPathSecurity.isStrictlyContained(approvalURL, under: repository),
      EvaluationPathSecurity.isStrictlyContained(eventURL, under: evaluation)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(
      in: [
        repository, evaluation, state, promptURL, carrierURL, resultURL, manifestURL, approvalURL,
        eventURL,
      ]
    )
  }

  package enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case executionProfile = "execution_profile"
    case jobID = "job_id"
    case operationID = "operation_id"
    case attemptGeneration = "attempt_generation"
    case providerCallID = "provider_call_id"
    case kind
    case stateRoot = "state_root"
    case prompt
    case carrier
    case resultPath = "result_path"
    case manifest
    case authorization
  }
}

package struct EvaluationLearningCallRequestCore: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let executionProfile: EvaluationLearningExecutionProfile
  package let jobID: String
  package let operationID: String
  package let attemptGeneration: Int
  package let providerCallID: ProviderCallID
  package let kind: EvaluationLearningOperationKind
  package let stateRoot: String
  package let prompt: EvaluationLearningArtifactBinding
  package let carrier: EvaluationLearningArtifactBinding
  package let resultPath: String
  package let manifest: EvaluationLearningManifestBinding

  package var sha256: String {
    guard let data = try? EvaluationCanonicalJSON.data(encoding: self) else {
      return ""
    }
    return SHA256Digest.hex(data)
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case executionProfile = "execution_profile"
    case jobID = "job_id"
    case operationID = "operation_id"
    case attemptGeneration = "attempt_generation"
    case providerCallID = "provider_call_id"
    case kind
    case stateRoot = "state_root"
    case prompt
    case carrier
    case resultPath = "result_path"
    case manifest
  }
}

package struct EvaluationLearningCallUsage: Codable, Sendable, Equatable {
  package let providerCallID: ProviderCallID
  package let responsesSends: Int
  package let provenNotStartedResponsesSends: Int
  package let promptTokens: Int?
  package let completionTokens: Int?
  package let reportedTotalTokens: Int?
  package let accountedTokens: Int
  package let isEstimated: Bool

  package init(
    providerCallID: ProviderCallID,
    responsesSends: Int,
    provenNotStartedResponsesSends: Int,
    terminalUsage: ChatUsage?,
    missingUsageTokenProxy: Int
  ) throws {
    let reportedRow: EvaluationUsageAccountingRow?
    if let terminalUsage {
      let (reportedTotal, overflowed) = terminalUsage.promptTokens.addingReportingOverflow(
        terminalUsage.completionTokens
      )
      guard
        terminalUsage.promptTokens >= 0,
        terminalUsage.completionTokens >= 0,
        terminalUsage.totalTokens >= 0,
        overflowed == false,
        reportedTotal == terminalUsage.totalTokens
      else {
        throw EvaluationLearningAdmissionError.invalidBinding
      }
      promptTokens = terminalUsage.promptTokens
      completionTokens = terminalUsage.completionTokens
      reportedTotalTokens = terminalUsage.totalTokens
      reportedRow = EvaluationUsageAccountingRow(
        tokens: terminalUsage.totalTokens,
        isEstimated: false
      )
    } else {
      promptTokens = nil
      completionTokens = nil
      reportedTotalTokens = nil
      reportedRow = nil
    }

    guard
      missingUsageTokenProxy > 0,
      responsesSends >= 0,
      provenNotStartedResponsesSends >= 0,
      provenNotStartedResponsesSends <= responsesSends,
      reportedRow == nil || responsesSends - provenNotStartedResponsesSends > 0
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    self.providerCallID = providerCallID
    self.responsesSends = responsesSends
    self.provenNotStartedResponsesSends = provenNotStartedResponsesSends
    let rows = reportedRow.map { [$0] } ?? []
    accountedTokens = EvaluationResultAccounting.accountedTokens(
      responsesSends: responsesSends,
      provenNotStartedResponsesSends: provenNotStartedResponsesSends,
      usage: rows,
      missingUsageTokenProxy: missingUsageTokenProxy
    )
    let accountableSends = responsesSends - provenNotStartedResponsesSends
    isEstimated = accountableSends > rows.count
  }

  static func recordingFailure(
    providerCallID: ProviderCallID,
    error: any Error,
    recorder: EvaluationHTTPRecorder,
    missingUsageTokenProxy: Int
  ) async throws -> Self {
    if ProviderFailureAccounting.classify(error) == .notStarted {
      let before = await recorder.snapshot()
      let unresolved = before.responsesSends.count - before.provenNotStartedResponsesSends
      try await recorder.recordProvenNotStartedResponsesSends(unresolved)
    }
    let snapshot = await recorder.snapshot()
    return try Self(
      providerCallID: providerCallID,
      responsesSends: snapshot.responsesSends.count,
      provenNotStartedResponsesSends: snapshot.provenNotStartedResponsesSends,
      terminalUsage: nil,
      missingUsageTokenProxy: missingUsageTokenProxy
    )
  }

  package func validate(
    providerCallID: ProviderCallID,
    retryBudget: Int,
    maxOutputTokens: Int,
    missingUsageTokenProxy: Int
  ) throws {
    let reportedValues = [promptTokens, completionTokens, reportedTotalTokens]
    guard
      self.providerCallID == providerCallID,
      responsesSends >= 0,
      responsesSends <= retryBudget,
      provenNotStartedResponsesSends >= 0,
      provenNotStartedResponsesSends <= responsesSends,
      reportedValues.allSatisfy({ $0 == nil }) || reportedValues.allSatisfy({ $0 != nil })
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    let terminalUsage: ChatUsage?
    if let promptTokens,
      let completionTokens,
      let reportedTotalTokens
    {
      guard completionTokens <= maxOutputTokens else {
        throw EvaluationLearningAdmissionError.invalidBinding
      }
      terminalUsage = ChatUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: reportedTotalTokens
      )
    } else {
      terminalUsage = nil
    }
    let expected = try Self(
      providerCallID: providerCallID,
      responsesSends: responsesSends,
      provenNotStartedResponsesSends: provenNotStartedResponsesSends,
      terminalUsage: terminalUsage,
      missingUsageTokenProxy: missingUsageTokenProxy
    )
    guard accountedTokens == expected.accountedTokens, isEstimated == expected.isEstimated else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
  }

  package enum CodingKeys: String, CodingKey, CaseIterable {
    case providerCallID = "provider_call_id"
    case responsesSends = "responses_sends"
    case provenNotStartedResponsesSends = "proven_not_started_responses_sends"
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case reportedTotalTokens = "reported_total_tokens"
    case accountedTokens = "accounted_tokens"
    case isEstimated = "is_estimated"
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(providerCallID, forKey: .providerCallID)
    try container.encode(responsesSends, forKey: .responsesSends)
    try container.encode(provenNotStartedResponsesSends, forKey: .provenNotStartedResponsesSends)
    try container.encodeOptional(promptTokens, forKey: .promptTokens)
    try container.encodeOptional(completionTokens, forKey: .completionTokens)
    try container.encodeOptional(reportedTotalTokens, forKey: .reportedTotalTokens)
    try container.encode(accountedTokens, forKey: .accountedTokens)
    try container.encode(isEstimated, forKey: .isEstimated)
  }
}

package enum EvaluationLearningCallOutcome: String, Codable, Sendable {
  case response
  case failedNoCall = "failed_no_call"
  case failed
}

package struct EvaluationLearningCallProvenance: Codable, Sendable, Equatable {
  package let requestSHA256: String
  package let manifestSHA256: String
  package let freezeCommit: String
  package let executableSHA256: String
  package let promptSHA256: String
  package let carrierSHA256: String

  enum CodingKeys: String, CodingKey {
    case requestSHA256 = "request_sha256"
    case manifestSHA256 = "manifest_sha256"
    case freezeCommit = "freeze_commit"
    case executableSHA256 = "executable_sha256"
    case promptSHA256 = "prompt_sha256"
    case carrierSHA256 = "carrier_sha256"
  }
}

package struct EvaluationLearningCallResult: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let jobID: String
  package let operationID: String
  package let attemptGeneration: Int
  package let providerCallID: ProviderCallID
  package let kind: EvaluationLearningOperationKind
  package let outcome: EvaluationLearningCallOutcome
  package let failureCode: String?
  package let output: String?
  package let outputSHA256: String?
  package let finishReason: String?
  package let providerReference: String
  package let wireModel: String
  package let reportedModel: String?
  package let retryBudget: Int
  package let maxOutputTokens: Int
  package let maxOutputUTF8Bytes: Int
  package let maxOutputGraphemes: Int
  package let usage: EvaluationLearningCallUsage?
  package let provenance: EvaluationLearningCallProvenance

  package init(
    request: EvaluationLearningCallRequest,
    requestSHA256: String,
    outcome: EvaluationLearningCallOutcome,
    failureCode: String?,
    output: String?,
    finishReason: String?,
    reportedModel: String?,
    usage: EvaluationLearningCallUsage?,
    admissionContext: EvaluationLearningAdmissionContext
  ) throws {
    try request.validate()
    guard
      SHA256Digest.isCanonicalHex(requestSHA256),
      admissionContext.jobID == request.jobID,
      admissionContext.operationID == request.operationID,
      admissionContext.attemptGeneration == request.attemptGeneration,
      admissionContext.providerCallID == request.providerCallID,
      admissionContext.manifestSHA256 == request.manifest.manifestSHA256,
      admissionContext.route.retryBudget > 0,
      admissionContext.route.maxOutputTokens > 0,
      admissionContext.route.maxOutputUTF8Bytes > 0,
      admissionContext.route.maxOutputGraphemes > 0
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }

    schemaVersion = 1
    jobID = request.jobID
    operationID = request.operationID
    attemptGeneration = request.attemptGeneration
    providerCallID = request.providerCallID
    kind = request.kind
    self.outcome = outcome
    self.failureCode = failureCode
    self.output = output
    outputSHA256 = output.map { SHA256Digest.hex(Data($0.utf8)) }
    self.finishReason = finishReason
    providerReference = admissionContext.route.providerReference
    wireModel = admissionContext.route.wireModel
    self.reportedModel = reportedModel
    retryBudget = admissionContext.route.retryBudget
    maxOutputTokens = admissionContext.route.maxOutputTokens
    maxOutputUTF8Bytes = admissionContext.route.maxOutputUTF8Bytes
    maxOutputGraphemes = admissionContext.route.maxOutputGraphemes
    self.usage = usage
    provenance = EvaluationLearningCallProvenance(
      requestSHA256: requestSHA256,
      manifestSHA256: admissionContext.manifestSHA256,
      freezeCommit: admissionContext.freezeCommit,
      executableSHA256: admissionContext.executableSHA256,
      promptSHA256: request.prompt.sha256,
      carrierSHA256: request.carrier.sha256
    )
    try validate(missingUsageTokenProxy: admissionContext.missingUsageTokenProxy)
  }

  // swiftlint:disable:next function_body_length
  package func validate(missingUsageTokenProxy: Int) throws {
    guard
      schemaVersion == 1,
      kind == .evaluator || kind == .reflector,
      jobID.isEmpty == false,
      operationID.isEmpty == false,
      attemptGeneration > 0,
      EvaluationLearningCallRequest.isCanonical(providerCallID),
      providerReference.isEmpty == false,
      wireModel.isEmpty == false,
      retryBudget > 0,
      maxOutputTokens > 0,
      maxOutputUTF8Bytes > 0,
      maxOutputGraphemes > 0,
      SHA256Digest.isCanonicalHex(provenance.requestSHA256),
      SHA256Digest.isCanonicalHex(provenance.manifestSHA256),
      Self.isCommit(provenance.freezeCommit),
      SHA256Digest.isCanonicalHex(provenance.executableSHA256),
      SHA256Digest.isCanonicalHex(provenance.promptSHA256),
      SHA256Digest.isCanonicalHex(provenance.carrierSHA256),
      finishReason.map(Self.isBoundedText) ?? true,
      reportedModel.map(Self.isBoundedText) ?? true
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    if let output {
      guard
        output.utf8.count <= maxOutputUTF8Bytes,
        output.count <= maxOutputGraphemes,
        outputSHA256 == SHA256Digest.hex(Data(output.utf8))
      else {
        throw EvaluationLearningAdmissionError.invalidBinding
      }
    } else if outputSHA256 != nil {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    if let usage {
      try usage.validate(
        providerCallID: providerCallID,
        retryBudget: retryBudget,
        maxOutputTokens: maxOutputTokens,
        missingUsageTokenProxy: missingUsageTokenProxy
      )
    }

    switch outcome {
    case .response:
      guard
        failureCode == nil,
        output != nil,
        usage?.responsesSends ?? 0 > 0
      else {
        throw EvaluationLearningAdmissionError.invalidBinding
      }
    case .failedNoCall:
      guard
        Self.isFailureCode(failureCode),
        output == nil,
        finishReason == nil,
        reportedModel == nil,
        usage == nil
      else {
        throw EvaluationLearningAdmissionError.invalidBinding
      }
    case .failed:
      guard
        Self.isFailureCode(failureCode),
        output == nil,
        finishReason == nil,
        reportedModel == nil,
        usage?.responsesSends ?? 0 > 0
      else {
        throw EvaluationLearningAdmissionError.invalidBinding
      }
    }
  }

  package enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case jobID = "job_id"
    case operationID = "operation_id"
    case attemptGeneration = "attempt_generation"
    case providerCallID = "provider_call_id"
    case kind
    case outcome
    case failureCode = "failure_code"
    case output
    case outputSHA256 = "output_sha256"
    case finishReason = "finish_reason"
    case providerReference = "provider_reference"
    case wireModel = "wire_model"
    case reportedModel = "reported_model"
    case retryBudget = "retry_budget"
    case maxOutputTokens = "max_output_tokens"
    case maxOutputUTF8Bytes = "max_output_utf8_bytes"
    case maxOutputGraphemes = "max_output_graphemes"
    case usage
    case provenance
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(jobID, forKey: .jobID)
    try container.encode(operationID, forKey: .operationID)
    try container.encode(attemptGeneration, forKey: .attemptGeneration)
    try container.encode(providerCallID, forKey: .providerCallID)
    try container.encode(kind, forKey: .kind)
    try container.encode(outcome, forKey: .outcome)
    try container.encodeOptional(failureCode, forKey: .failureCode)
    try container.encodeOptional(output, forKey: .output)
    try container.encodeOptional(outputSHA256, forKey: .outputSHA256)
    try container.encodeOptional(finishReason, forKey: .finishReason)
    try container.encode(providerReference, forKey: .providerReference)
    try container.encode(wireModel, forKey: .wireModel)
    try container.encodeOptional(reportedModel, forKey: .reportedModel)
    try container.encode(retryBudget, forKey: .retryBudget)
    try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
    try container.encode(maxOutputUTF8Bytes, forKey: .maxOutputUTF8Bytes)
    try container.encode(maxOutputGraphemes, forKey: .maxOutputGraphemes)
    try container.encodeOptional(usage, forKey: .usage)
    try container.encode(provenance, forKey: .provenance)
  }
}

extension EvaluationResultAccounting {
  static func accountedTokens(
    responsesSends: Int,
    provenNotStartedResponsesSends: Int,
    usage: [EvaluationUsageAccountingRow],
    missingUsageTokenProxy: Int
  ) -> Int {
    let safeSends = max(0, responsesSends)
    let accountableSends = max(0, safeSends - max(0, provenNotStartedResponsesSends))
    let reported = usage.prefix(accountableSends).reduce(0) { total, row in
      let rowTokens = row.isEstimated ? missingUsageTokenProxy : max(0, row.tokens)
      return SaturatingArithmetic.sum(total, rowTokens)
    }
    let missing = max(0, accountableSends - usage.count)
    let missingTokens = SaturatingArithmetic.product(missing, missingUsageTokenProxy)
    return SaturatingArithmetic.sum(reported, missingTokens)
  }
}

private extension EvaluationLearningCallRequest {
  static func absoluteURL(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path)
    guard path.hasPrefix("/"), url.standardizedFileURL.path == path else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    return url
  }

  static func isCanonical(_ providerCallID: ProviderCallID) -> Bool {
    guard let identifier = UUID(uuidString: providerCallID.rawValue) else {
      return false
    }
    return identifier.uuidString.lowercased() == providerCallID.rawValue
  }

  static func requireExactKeys(_ object: [String: Any], keys: Set<String>) throws {
    guard Set(object.keys) == keys else {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
  }

  static func requireExactObjectKeys(
    in root: [String: Any],
    path: [String],
    keys: Set<String>
  ) throws {
    var value: Any = root
    for component in path {
      guard let object = value as? [String: Any], let next = object[component] else {
        throw EvaluationLearningAdmissionError.invalidJSON
      }
      value = next
    }
    guard let object = value as? [String: Any], Set(object.keys) == keys else {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
  }
}

private extension EvaluationLearningCallResult {
  static func isCommit(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy { "0123456789abcdef".contains($0) }
  }

  static func isFailureCode(_ value: String?) -> Bool {
    guard
      let value,
      (1...64).contains(value.count),
      value.first?.isLowercase == true
    else {
      return false
    }
    return value.allSatisfy { character in
      character.isLowercase || character.isNumber || character == "_"
    }
  }

  static func isBoundedText(_ value: String) -> Bool {
    value.isEmpty == false
      && value.utf8.count <= 256
      && value.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F
      }
  }
}

private extension KeyedEncodingContainer {
  mutating func encodeOptional<Value: Encodable>(
    _ value: Value?,
    forKey key: Key
  ) throws {
    if let value {
      try encode(value, forKey: key)
    } else {
      try encodeNil(forKey: key)
    }
  }
}
