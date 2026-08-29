import ClawAgent
import ClawCore
import ClawLLM
import Foundation

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
