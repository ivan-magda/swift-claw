import AsyncHTTPClient
import ClawAgent
import ClawCore
import ClawHTTP
import ClawLLM
import ClawSecrets
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
    try EvaluationLearningAdmissionVerifier.requireExactKeys(
      object,
      keys: Set(CodingKeys.allCases.map(\.rawValue))
    )
    try EvaluationLearningAdmissionVerifier.requireExactObjectKeys(
      in: object,
      path: [CodingKeys.prompt.rawValue],
      keys: ["path", "sha256"]
    )
    try EvaluationLearningAdmissionVerifier.requireExactObjectKeys(
      in: object,
      path: [CodingKeys.carrier.rawValue],
      keys: ["path", "sha256"]
    )
    try EvaluationLearningAdmissionVerifier.requireExactObjectKeys(
      in: object,
      path: [CodingKeys.manifest.rawValue],
      keys: [
        "repository_root", "evaluation_root", "manifest_path", "manifest_sha256",
        "owner_approval",
      ]
    )
    try EvaluationLearningAdmissionVerifier.requireExactObjectKeys(
      in: object,
      path: [CodingKeys.manifest.rawValue, "owner_approval"],
      keys: ["path", "sha256"]
    )
    try EvaluationLearningAdmissionVerifier.requireExactObjectKeys(
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
      EvaluationLearningAdmissionVerifier.isCanonicalProviderCallID(providerCallID),
      SHA256Digest.isCanonicalHex(prompt.sha256),
      SHA256Digest.isCanonicalHex(carrier.sha256),
      SHA256Digest.isCanonicalHex(manifest.manifestSHA256),
      SHA256Digest.isCanonicalHex(manifest.ownerApproval.sha256),
      SHA256Digest.isCanonicalHex(authorization.eventSHA256)
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }

    let repository = try EvaluationLearningAdmissionVerifier.absoluteURL(manifest.repositoryRoot)
    let evaluation = try EvaluationLearningAdmissionVerifier.absoluteURL(manifest.evaluationRoot)
    let state = try EvaluationLearningAdmissionVerifier.absoluteURL(stateRoot)
    let promptURL = try EvaluationLearningAdmissionVerifier.absoluteURL(prompt.path)
    let carrierURL = try EvaluationLearningAdmissionVerifier.absoluteURL(carrier.path)
    let resultURL = try EvaluationLearningAdmissionVerifier.absoluteURL(resultPath)
    let manifestURL = try EvaluationLearningAdmissionVerifier.absoluteURL(manifest.manifestPath)
    let approvalURL = try EvaluationLearningAdmissionVerifier.absoluteURL(
      manifest.ownerApproval.path
    )
    let eventURL = try EvaluationLearningAdmissionVerifier.absoluteURL(authorization.eventPath)
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
    failureCode: EvaluationAttemptOutcome?,
    output: String?,
    finishReason: String?,
    reportedModel: String?,
    usage: EvaluationLearningCallUsage?,
    admissionContext: EvaluationLearningAdmissionContext
  ) throws {
    try request.validate()
    let canonicalRequestSHA256 = SHA256Digest.hex(
      try EvaluationCanonicalJSON.data(encoding: request)
    )
    guard
      requestSHA256 == canonicalRequestSHA256,
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
    self.failureCode = failureCode?.rawValue
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
      EvaluationLearningAdmissionVerifier.isCanonicalProviderCallID(providerCallID),
      providerReference.isEmpty == false,
      wireModel.isEmpty == false,
      retryBudget > 0,
      maxOutputTokens > 0,
      maxOutputUTF8Bytes > 0,
      maxOutputGraphemes > 0,
      SHA256Digest.isCanonicalHex(provenance.requestSHA256),
      SHA256Digest.isCanonicalHex(provenance.manifestSHA256),
      EvaluationLearningAdmissionVerifier.isCommit(provenance.freezeCommit),
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
        usage != nil
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

package struct EvaluationLearningCallRunner: Sendable {
  package init() {}

  // The frozen runner boundary carries every independently hashed or admitted input explicitly.
  // swiftlint:disable:next function_body_length function_parameter_count
  package func run(
    request: EvaluationLearningCallRequest,
    requestSHA256: String,
    prompt: String,
    carrier: String,
    binding: LLMRouteBinding,
    admissionContext: EvaluationLearningAdmissionContext,
    liveAdmission: @escaping @Sendable () async -> ProviderRoundTripAdmission
  ) async throws -> EvaluationLearningCallResult {
    guard
      Self.isAdmitted(
        request: request,
        requestSHA256: requestSHA256,
        prompt: prompt,
        carrier: carrier,
        binding: binding,
        context: admissionContext
      )
    else {
      return try Self.failedNoCall(
        request: request,
        requestSHA256: requestSHA256,
        outcome: .harnessFailure,
        context: admissionContext
      )
    }
    guard await liveAdmission() == .allow else {
      return try Self.failedNoCall(
        request: request,
        requestSHA256: requestSHA256,
        outcome: .budgetStopped,
        context: admissionContext
      )
    }

    let outputLimiter = AttemptOutputLimiter(
      limits: AttemptOutputLimits(
        maximumUTF8Bytes: admissionContext.route.maxOutputUTF8Bytes,
        maximumGraphemes: admissionContext.route.maxOutputGraphemes
      )
    )
    let outputScope = outputLimiter.beginRound()
    let chatRequest = ChatRequest(
      model: admissionContext.route.wireModel,
      messages: [
        ChatMessage(role: .system, content: prompt),
        ChatMessage(role: .user, content: carrier),
      ],
      maxOutputTokens: admissionContext.route.maxOutputTokens,
      tools: [],
      responseFormat: nil,
      sessionId: nil,
      outputScope: outputScope,
      terminalValidationPolicy: .throughStreamEnd
    )

    do {
      let response = try await binding.provider.complete(request: chatRequest)
      return try Self.result(
        response: response,
        outputScope: outputScope,
        request: request,
        requestSHA256: requestSHA256,
        context: admissionContext
      )
    } catch {
      let accounting = ProviderFailureAccounting.classify(error)
      let usage = try Self.failureUsage(
        request: request,
        accounting: accounting,
        context: admissionContext
      )
      return try EvaluationLearningCallResult(
        request: request,
        requestSHA256: requestSHA256,
        outcome: .failed,
        failureCode: Self.failureOutcome(for: error),
        output: nil,
        finishReason: nil,
        reportedModel: nil,
        usage: usage,
        admissionContext: admissionContext
      )
    }
  }
}

package struct EvaluationLearningCall: Sendable {
  package init() {}

  static var productionExecutablePath: String { CommandLine.arguments[0] }

  package func run(
    request: EvaluationLearningCallRequest
  ) async throws -> EvaluationLearningCallResult {
    return try await run(
      request: request,
      makeResource: Self.productionResourceFactory(
        admissionVerifier: Self.productionAdmissionVerifier()
      )
    )
  }

  static func productionResourceFactory(
    admissionVerifier: EvaluationLearningAdmissionVerifier
  )
    -> @Sendable (EvaluationLearningCallResourceFactoryInput) async throws ->
    EvaluationLearningCallResource
  {
    { input in
      try await Self.makeLiveResource(input: input, admissionVerifier: admissionVerifier)
    }
  }

  package func run(
    request: EvaluationLearningCallRequest,
    makeResource:
      @escaping @Sendable (
        EvaluationLearningCallResourceFactoryInput
      ) async throws -> EvaluationLearningCallResource
  ) async throws -> EvaluationLearningCallResult {
    try request.validate()
    let requestData = try EvaluationCanonicalJSON.data(encoding: request)
    let requestSHA256 = SHA256Digest.hex(requestData)
    let stateRoot = try EvaluationLearningAdmissionVerifier.absoluteURL(request.stateRoot)
    let resultURL = try EvaluationLearningAdmissionVerifier.absoluteURL(request.resultPath)

    return try await EvaluationWorkerLifecycle.withProductionLockOnly(stateRoot: stateRoot) { _ in
      let prompt = try Self.readArtifact(request.prompt)
      let carrier = try Self.readArtifact(request.carrier)
      let factoryInput = EvaluationLearningCallResourceFactoryInput(
        request: request,
        requestSHA256: requestSHA256
      )

      return try await EvaluationWorkerLifecycle.withResource(
        makeResource: {
          try await makeResource(factoryInput)
        },
        operation: { resource in
          let context = resource.admission.context
          try Self.validate(request: request, context: context)
          guard resource.roster.hasFallback == false else {
            throw EvaluationLearningAdmissionError.invalidBinding
          }
          let result = try await EvaluationLearningCallRunner().run(
            request: request,
            requestSHA256: requestSHA256,
            prompt: prompt,
            carrier: carrier,
            binding: resource.roster.primary,
            admissionContext: context,
            liveAdmission: {
              await resource.admission.evaluate()
            }
          )
          let reconciled = try await Self.reconcile(
            result: result,
            request: request,
            requestSHA256: requestSHA256,
            context: context,
            resource: resource
          )
          let resultData = try EvaluationCanonicalJSON.data(encoding: reconciled)
          try EvaluationDurablePublication.publishExclusive(resultData, to: resultURL)
          return reconciled
        }
      )
    }
  }
}

package struct EvaluationLearningCallResourceFactoryInput: Sendable {
  package let request: EvaluationLearningCallRequest
  package let requestSHA256: String

  package init(request: EvaluationLearningCallRequest, requestSHA256: String) {
    self.request = request
    self.requestSHA256 = requestSHA256
  }

  package func admission(
    using verifier: any EvaluationLearningAdmissionVerifying
  ) async throws -> EvaluationLearningCallAdmission {
    let context = try await verifier.verify(
      manifest: request.manifest,
      authorization: request.authorization,
      invocationCoreDigest: request.core.sha256,
      carrierSHA256: request.carrier.sha256,
      providerCallID: request.providerCallID,
      kind: request.kind
    )
    let liveAdmission = EvaluationLearningLiveAdmission(
      verifier: verifier,
      manifest: request.manifest,
      authorization: request.authorization,
      invocationCoreDigest: request.core.sha256,
      carrierSHA256: request.carrier.sha256,
      providerCallID: request.providerCallID,
      kind: request.kind,
      initial: context
    )
    return EvaluationLearningCallAdmission(
      context: context,
      liveAdmission: {
        do {
          _ = try EvaluationLearningCall.readArtifact(request.prompt)
          _ = try EvaluationLearningCall.readArtifact(request.carrier)
        } catch {
          return .deny(cap: "evaluation-learning-integrity")
        }
        return await liveAdmission.evaluate()
      }
    )
  }
}

package struct EvaluationLearningCallAdmission: Sendable {
  package let context: EvaluationLearningAdmissionContext
  private let liveAdmission: @Sendable () async -> ProviderRoundTripAdmission

  package init(
    context: EvaluationLearningAdmissionContext,
    liveAdmission: @escaping @Sendable () async -> ProviderRoundTripAdmission
  ) {
    self.context = context
    self.liveAdmission = liveAdmission
  }

  func evaluate() async -> ProviderRoundTripAdmission {
    await liveAdmission()
  }
}

package struct EvaluationLearningCallResource: EvaluationWorkerResource {
  package let admission: EvaluationLearningCallAdmission
  package let roster: ProviderRoster
  private let credentialSource: any LLMCredentialSource
  private let closeTransport: @Sendable () async throws -> Void
  private let observeHTTP: @Sendable () async -> EvaluationLearningCallHTTPObservation
  private let markProvenNotStarted: @Sendable (Int) async throws -> Void

  package init(
    admission: EvaluationLearningCallAdmission,
    roster: ProviderRoster,
    credentialSource: any LLMCredentialSource,
    closeTransport: @escaping @Sendable () async throws -> Void,
    observeHTTP: @escaping @Sendable () async -> EvaluationLearningCallHTTPObservation,
    markProvenNotStarted: @escaping @Sendable (Int) async throws -> Void
  ) {
    self.admission = admission
    self.roster = roster
    self.credentialSource = credentialSource
    self.closeTransport = closeTransport
    self.observeHTTP = observeHTTP
    self.markProvenNotStarted = markProvenNotStarted
  }

  func shutdownCredentials() async throws {
    try await credentialSource.shutdown()
  }

  func shutdownTransport() async throws {
    try await closeTransport()
  }

  func httpObservation() async -> EvaluationLearningCallHTTPObservation {
    await observeHTTP()
  }

  func recordProvenNotStarted(_ count: Int) async throws {
    try await markProvenNotStarted(count)
  }
}

package struct EvaluationLearningCallHTTPObservation: Sendable, Equatable {
  package let responsesSends: Int
  package let provenNotStartedResponsesSends: Int
  package let hasIntegrityFailures: Bool

  package init(
    responsesSends: Int,
    provenNotStartedResponsesSends: Int,
    hasIntegrityFailures: Bool
  ) {
    self.responsesSends = responsesSends
    self.provenNotStartedResponsesSends = provenNotStartedResponsesSends
    self.hasIntegrityFailures = hasIntegrityFailures
  }
}

// MARK: - Pure Call Validation

private extension EvaluationLearningCallRunner {
  // swiftlint:disable:next function_parameter_count
  static func isAdmitted(
    request: EvaluationLearningCallRequest,
    requestSHA256: String,
    prompt: String,
    carrier: String,
    binding: LLMRouteBinding,
    context: EvaluationLearningAdmissionContext
  ) -> Bool {
    let expectedOutputTokens =
      switch request.kind {
      case .evaluator: 512
      case .reflector: 768
      case .task: 0
      }
    let canonicalRequestSHA256 = try? SHA256Digest.hex(
      EvaluationCanonicalJSON.data(encoding: request)
    )
    return canonicalRequestSHA256 == requestSHA256
      && request.providerCallID == context.providerCallID
      && request.jobID == context.jobID
      && request.operationID == context.operationID
      && request.attemptGeneration == context.attemptGeneration
      && request.manifest.manifestSHA256 == context.manifestSHA256
      && binding.configuredReference == context.route.providerReference
      && binding.wireModel == context.route.wireModel
      && binding.costPolicy == .includedPlan
      && binding.reservationPolicy == .chatGPTReplayState
      && context.route.retryBudget == 3
      && context.route.maxOutputTokens == expectedOutputTokens
      && SHA256Digest.hex(Data(prompt.utf8)) == request.prompt.sha256
      && SHA256Digest.hex(Data(carrier.utf8)) == request.carrier.sha256
  }

  static func failedNoCall(
    request: EvaluationLearningCallRequest,
    requestSHA256 _: String,
    outcome: EvaluationAttemptOutcome,
    context: EvaluationLearningAdmissionContext
  ) throws -> EvaluationLearningCallResult {
    let canonicalRequestSHA256 = SHA256Digest.hex(
      try EvaluationCanonicalJSON.data(encoding: request)
    )
    return try EvaluationLearningCallResult(
      request: request,
      requestSHA256: canonicalRequestSHA256,
      outcome: .failedNoCall,
      failureCode: outcome,
      output: nil,
      finishReason: nil,
      reportedModel: nil,
      usage: nil,
      admissionContext: context
    )
  }

  static func result(
    response: ChatResponse,
    outputScope: AttemptOutputScope,
    request: EvaluationLearningCallRequest,
    requestSHA256: String,
    context: EvaluationLearningAdmissionContext
  ) throws -> EvaluationLearningCallResult {
    var failure: EvaluationAttemptOutcome?
    do {
      try outputScope.finalize(response)
    } catch {
      failure = .localOutputLimit
    }
    if failure == nil, response.toolCalls.isEmpty == false {
      failure = .toolContractFailure
    } else if failure == nil,
      let reportedModel = response.reportedModel,
      reportedModel != context.route.wireModel
    {
      failure = .modelIdentityMismatch
    } else if failure == nil,
      let usage = response.usage,
      usage.completionTokens > context.route.maxOutputTokens
    {
      failure = .budgetStopped
    }

    let terminalUsage = failure == .budgetStopped ? nil : response.usage
    let usage = try EvaluationLearningCallUsage(
      providerCallID: request.providerCallID,
      responsesSends: 1,
      provenNotStartedResponsesSends: 0,
      terminalUsage: terminalUsage,
      missingUsageTokenProxy: context.missingUsageTokenProxy
    )
    if let failure {
      return try EvaluationLearningCallResult(
        request: request,
        requestSHA256: requestSHA256,
        outcome: .failed,
        failureCode: failure,
        output: nil,
        finishReason: nil,
        reportedModel: nil,
        usage: usage,
        admissionContext: context
      )
    }
    return try EvaluationLearningCallResult(
      request: request,
      requestSHA256: requestSHA256,
      outcome: .response,
      failureCode: nil,
      output: response.content,
      finishReason: response.finishReason,
      reportedModel: response.reportedModel,
      usage: usage,
      admissionContext: context
    )
  }

  static func failureUsage(
    request: EvaluationLearningCallRequest,
    accounting: ProviderFailureAccounting,
    context: EvaluationLearningAdmissionContext
  ) throws -> EvaluationLearningCallUsage {
    let provenNotStarted: Int
    switch accounting {
    case .notStarted:
      provenNotStarted = 1
    case .mayHaveStarted:
      provenNotStarted = 0
    }
    return try EvaluationLearningCallUsage(
      providerCallID: request.providerCallID,
      responsesSends: 1,
      provenNotStartedResponsesSends: provenNotStarted,
      terminalUsage: nil,
      missingUsageTokenProxy: context.missingUsageTokenProxy
    )
  }

  static func failureOutcome(for error: any Error) -> EvaluationAttemptOutcome {
    switch ProviderError.cause(of: error) {
    case .authenticationRequired:
      .authenticationRequired
    case .accessDenied:
      .accessDenied
    case .quotaLimited:
      .quotaLimited
    case .invalidProviderState:
      .invalidProviderState
    case .localOutputLimit:
      .localOutputLimit
    case .modelIdentityMismatch:
      .modelIdentityMismatch
    default:
      .providerFailure
    }
  }
}

// MARK: - Live Call Composition

private extension EvaluationLearningCall {
  static func productionAdmissionVerifier() -> EvaluationLearningAdmissionVerifier {
    EvaluationLearningAdmissionVerifier(
      runningExecutablePath: {
        CommandLine.arguments[0]
      },
      readFile: { url in
        try EvaluationPathSecurity.readRegularSingleLinkFile(
          at: url,
          maximumByteCount: 256 * 1_024 * 1_024
        )
      }
    )
  }

  static func readArtifact(_ binding: EvaluationLearningArtifactBinding) throws -> String {
    let url = try EvaluationLearningAdmissionVerifier.absoluteURL(binding.path)
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    guard
      SHA256Digest.hex(data) == binding.sha256,
      let text = String(data: data, encoding: .utf8)
    else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
    return text
  }

  static func validate(
    request: EvaluationLearningCallRequest,
    context: EvaluationLearningAdmissionContext
  ) throws {
    let expectedOutputTokens =
      switch request.kind {
      case .evaluator: 512
      case .reflector: 768
      case .task: 0
      }
    guard
      context.jobID == request.jobID,
      context.operationID == request.operationID,
      context.attemptGeneration == request.attemptGeneration,
      context.providerCallID == request.providerCallID,
      context.manifestSHA256 == request.manifest.manifestSHA256,
      context.missingUsageTokenProxy > 0,
      context.route.retryBudget == 3,
      context.route.maxOutputTokens == expectedOutputTokens
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
  }

  // Resource construction stays linear so the catch visibly owns the transport on every failure.
  // swiftlint:disable:next function_body_length
  static func makeLiveResource(
    input: EvaluationLearningCallResourceFactoryInput,
    admissionVerifier: any EvaluationLearningAdmissionVerifying
  ) async throws -> EvaluationLearningCallResource {
    let admission = try await input.admission(using: admissionVerifier)
    let context = admission.context
    let stateRoot = try EvaluationLearningAdmissionVerifier.absoluteURL(input.request.stateRoot)
    let route = try LLMProviderRegistry.resolve(
      modelReference: context.route.providerReference,
      configuredBaseURL: ""
    )
    guard
      route.descriptor == .openAIChatGPT,
      route.configuredReference == context.route.providerReference,
      route.wireModel == context.route.wireModel
    else {
      throw EvaluationLearningAdmissionError.invalidBinding
    }
    let settings = LLMConfig(
      route: route,
      maxOutputTokens: context.route.maxOutputTokens,
      retryBudget: context.route.retryBudget,
      requestTimeoutSeconds: 180,
      streamingEnabled: false,
      structuredOutput: .off,
      fallbackRoute: nil
    )
    let client = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: HTTPClientProfile.protectedEgress.configuration
    )
    let recorder = EvaluationHTTPRecorder(
      base: AsyncHTTPExecutor(client: client),
      expectedWireModel: context.route.wireModel,
      maximumResponsesSends: context.route.retryBudget
    )
    do {
      let stack = try ProviderStackFactory.make(
        route: route,
        settings: settings,
        loadStaticBearer: { nil },
        makeManagedCredentialStore: {
          EncryptedLLMCredentialStore(stateRoot: stateRoot)
        },
        http: recorder,
        buildVersion: "swift-claw-evaluation-v1"
      )
      return EvaluationLearningCallResource(
        admission: admission,
        roster: ProviderRoster(primary: stack.binding),
        credentialSource: stack.credentialSource,
        closeTransport: {
          try await client.shutdown()
        },
        observeHTTP: {
          let snapshot = await recorder.snapshot()
          return EvaluationLearningCallHTTPObservation(
            responsesSends: snapshot.responsesSends.count,
            provenNotStartedResponsesSends: snapshot.provenNotStartedResponsesSends,
            hasIntegrityFailures: snapshot.integrityFailures.isEmpty == false
          )
        },
        markProvenNotStarted: { count in
          try await recorder.recordProvenNotStartedResponsesSends(count)
        }
      )
    } catch {
      try? await client.shutdown()
      throw error
    }
  }

  static func reconcile(
    result: EvaluationLearningCallResult,
    request: EvaluationLearningCallRequest,
    requestSHA256: String,
    context: EvaluationLearningAdmissionContext,
    resource: EvaluationLearningCallResource
  ) async throws -> EvaluationLearningCallResult {
    var observation = await resource.httpObservation()
    if result.usage?.provenNotStartedResponsesSends == 1 {
      let unresolved = observation.responsesSends - observation.provenNotStartedResponsesSends
      try await resource.recordProvenNotStarted(unresolved)
      observation = await resource.httpObservation()
    }
    guard observation.hasIntegrityFailures == false else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
    if result.outcome == .failedNoCall {
      guard observation.responsesSends == 0 else {
        throw EvaluationLearningAdmissionError.integrityFailure
      }
      return result
    }
    let permittedSends =
      result.outcome == .response
      ? (1...context.route.retryBudget).contains(observation.responsesSends)
      : (0...context.route.retryBudget).contains(observation.responsesSends)
    guard
      permittedSends,
      observation.provenNotStartedResponsesSends <= observation.responsesSends
    else {
      throw EvaluationLearningAdmissionError.integrityFailure
    }
    let terminalUsage: ChatUsage?
    if let usage = result.usage,
      let promptTokens = usage.promptTokens,
      let completionTokens = usage.completionTokens,
      let totalTokens = usage.reportedTotalTokens
    {
      terminalUsage = ChatUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens
      )
    } else {
      terminalUsage = nil
    }
    let usage = try EvaluationLearningCallUsage(
      providerCallID: request.providerCallID,
      responsesSends: observation.responsesSends,
      provenNotStartedResponsesSends: observation.provenNotStartedResponsesSends,
      terminalUsage: terminalUsage,
      missingUsageTokenProxy: context.missingUsageTokenProxy
    )
    return try EvaluationLearningCallResult(
      request: request,
      requestSHA256: requestSHA256,
      outcome: result.outcome,
      failureCode: result.failureCode.flatMap(EvaluationAttemptOutcome.init(rawValue:)),
      output: result.output,
      finishReason: result.finishReason,
      reportedModel: result.reportedModel,
      usage: usage,
      admissionContext: context
    )
  }
}

private extension EvaluationLearningCallResult {
  static func isFailureCode(_ value: String?) -> Bool {
    guard let value, let outcome = EvaluationAttemptOutcome(rawValue: value) else {
      return false
    }
    return outcome != .completed
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
