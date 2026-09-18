import ClawCore
import Foundation

extension LearningOperationRunner {
  /// The frozen algorithm's reflector ceiling, independent from the scheduled job's own cap.
  public static let reflectorOutputTokenCap = 768

  /// One reflection for one frozen trigger, or no call. The trigger cannot affect ordinary task
  /// delivery, so every store and provider failure is contained and logged here.
  public func runReflection(trigger: TriggerIdentity, now: Date) async {
    do {
      try await reflect(trigger: trigger, now: now)
    } catch {
      logger.error("trigger \(trigger.digest.rawValue) could not be reflected: \(error)")
    }
  }
}

// MARK: - Reflection Sequence

private extension LearningOperationRunner {
  func reflect(trigger: TriggerIdentity, now: Date) async throws {
    guard let preparation = try learning.prepareReflection(trigger: trigger) else {
      return
    }
    let key = LearningOperationKey.reflection(
      jobID: trigger.jobID,
      epoch: trigger.epoch,
      triggerDigest: trigger.digest
    )
    guard let claim = try learning.claimOperation(key, now: now) else {
      return
    }

    let carrier = try ReflectorCarrier(
      stableLessons: preparation.stableLessons.lessons,
      evaluations: preparation.evaluations.map(\.summary),
      issueCodes: trigger.issueCodes,
      ownerPayloads: preparation.ownerPayloads.map(\.payload)
    )
    // Encode once. These exact bytes are the user message, the privacy decision, the digest saved
    // at authorization and the manifest edge saved at completion.
    let bytes = try CanonicalJSON.data(encoding: carrier)
    // swiftlint:disable:next optional_data_string_conversion
    let serialized = String(decoding: bytes, as: UTF8.self)
    let messages = reflectionMessages(carrier: serialized)
    let route = roster.startingRoute(primaryIsCooling: await cooldown?.isCooling() == true)
    let call = ReflectionCall(
      operationID: claim.id,
      callID: providerCallIDGenerator.next(),
      carrierDigest: CarrierDigest(rawValue: SHA256Digest.hex(bytes)),
      authorization: ReflectionAuthorization(preparation: preparation),
      messages: messages
    )
    guard try authorizeReflection(call, route: route, serialized: serialized, now: now) else {
      return
    }
    await dispatchReflection(call, preparation: preparation, starting: route, now: now)
  }

  func authorizeReflection(
    _ call: ReflectionCall,
    route: RouteSelection,
    serialized: String,
    now: Date
  ) throws -> Bool {
    let usageAccountant = accountant(for: route.binding, outputCap: Self.reflectorOutputTokenCap)
    let estimate = usageAccountant.preflightEstimate(context: call.messages)
    let authorization = LearningAuthorization(
      operationID: call.operationID,
      carrier: CarrierAuthorization(
        sourceDigest: call.authorization.trigger.digest.rawValue,
        digest: call.carrierDigest,
        isPermitted: redactor.redact(serialized) == serialized
      ),
      estimatedTokens: estimate.totalTokens,
      estimatedCostUSD: estimate.costUSD,
      configuredRoute: route.binding.configuredReference,
      providerCallID: call.callID,
      budget: BudgetGate(budget: budget, costPolicy: route.binding.costPolicy),
      context: .reflection(call.authorization)
    )
    switch try learning.authorizeAndStartOperation(authorization, now: now) {
    case .started:
      return true
    case .deniedNoCall(let failure):
      logger.info("reflection \(call.operationID.rawValue) refused: \(failure.rawValue)")
      return false
    case .superseded:
      return false
    }
  }
}

// MARK: - Reflection Dispatch

private extension LearningOperationRunner {
  func dispatchReflection(
    _ call: ReflectionCall,
    preparation: ReflectionPreparation,
    starting: RouteSelection,
    now: Date
  ) async {
    let attempt = await dispatchInference(
      messages: call.messages,
      outputCap: Self.reflectorOutputTokenCap,
      starting: starting
    )
    switch attempt.result {
    case .response(let response):
      commitReflection(
        response,
        call: call,
        preparation: preparation,
        route: attempt.route,
        now: now
      )
    case .failed(let error):
      commitReflection(failure: error, call: call, route: attempt.route, now: now)
    }
  }
}

// MARK: - Reflection Result

private extension LearningOperationRunner {
  func commitReflection(
    _ response: ChatResponse,
    call: ReflectionCall,
    preparation: ReflectionPreparation,
    route: LLMRouteBinding,
    now: Date
  ) {
    let usageAccountant = accountant(for: route, outputCap: Self.reflectorOutputTokenCap)
    let usage = LearningCallUsage(
      model: route.configuredReference,
      resolved: usageAccountant.reconciled(for: response, context: call.messages)
    )
    let product: LearningOperationProduct
    do {
      let reply = FencedJSONReply.unfenced(response.content)
      let output = try JSONDecoder().decode(ReflectorOutput.self, from: Data(reply.utf8))
      product = try reflectionProduct(
        output: output,
        reply: reply,
        call: call,
        preparation: preparation
      )
    } catch {
      logger.info("reflection \(call.operationID.rawValue) returned an unusable reply: \(error)")
      finishReflection(call, usage: usage, product: .failure(.schemaInvalid), now: now)
      return
    }
    finishReflection(call, usage: usage, product: product, now: now)
  }

  func commitReflection(
    failure error: any Error,
    call: ReflectionCall,
    route: LLMRouteBinding,
    now: Date
  ) {
    let usage = failedCallUsage(
      error,
      context: call.messages,
      accountant: accountant(for: route, outputCap: Self.reflectorOutputTokenCap)
    )
    logger.info("reflection \(call.operationID.rawValue) failed at the provider: \(error)")
    finishReflection(call, usage: usage, product: .failure(.providerTerminal), now: now)
  }

  func reflectionProduct(
    output: ReflectorOutput,
    reply: String,
    call: ReflectionCall,
    preparation: ReflectionPreparation
  ) throws -> LearningOperationProduct {
    let resultDigest = ReflectionResultDigest.of(Data(reply.utf8))
    guard let candidate = output.candidate else {
      let result = NoCandidateResult(
        algorithm: preparation.trigger.algorithm,
        triggerDigest: preparation.trigger.digest,
        operationID: call.operationID,
        carrierDigest: call.carrierDigest,
        resultDigest: resultDigest,
        authorization: call.authorization
      )
      return .noCandidate(result)
    }
    let replacement = try LessonSet.canonical(
      jobID: preparation.trigger.jobID,
      lessons: candidate.lessons
    )
    for lesson in replacement.lessons {
      guard redactor.redact(lesson) == lesson else {
        throw ReflectionValidationError.secretLeak
      }
    }
    // swiftlint:disable:next optional_data_string_conversion
    let replacementBytes = String(decoding: replacement.canonicalBytes, as: UTF8.self)
    guard redactor.redact(replacementBytes) == replacementBytes else {
      throw ReflectionValidationError.secretLeak
    }
    let manifest = CandidateSourceManifest(
      origin: .reflection,
      algorithm: preparation.trigger.algorithm,
      jobID: preparation.trigger.jobID,
      epoch: preparation.trigger.epoch,
      triggerDigest: preparation.trigger.digest,
      triggerReason: preparation.trigger.reason,
      qualifyingIssueCodes: preparation.trigger.issueCodes,
      operationID: call.operationID,
      carrierDigest: call.carrierDigest,
      resultDigest: resultDigest,
      baseDigest: preparation.trigger.stableDigest,
      baseRevision: preparation.stableRevision,
      feedbackRevision: preparation.trigger.feedbackRevision,
      evidence: preparation.evidenceSources,
      evaluations: preparation.evaluationSources,
      feedback: preparation.feedbackSources,
      predecessorCandidate: nil,
      predecessorFeedback: nil
    )
    return .candidate(try CandidateArtifact(replacement: replacement, manifest: manifest))
  }

  func finishReflection(
    _ call: ReflectionCall,
    usage: LearningCallUsage,
    product: LearningOperationProduct,
    now: Date
  ) {
    let committed: Bool
    do {
      committed = try learning.finishOperation(
        LearningOperationResult(operationID: call.operationID, usage: usage, product: product),
        now: now
      )
    } catch {
      logger.error("reflection \(call.operationID.rawValue) could not be committed: \(error)")
      return
    }
    guard committed, case .candidate(let artifact) = product else {
      return
    }
    do {
      _ = try learning.admitCandidate(digest: artifact.digest, redactor: redactor, now: now)
    } catch {
      logger.error("reflection \(call.operationID.rawValue) admission was deferred: \(error)")
    }
  }
}

// MARK: - Reflection Call Shapes

private extension LearningOperationRunner {
  struct ReflectionCall {
    let operationID: LearningOperationID
    let callID: ProviderCallID
    let carrierDigest: CarrierDigest
    let authorization: ReflectionAuthorization
    let messages: [ChatMessage]
  }

  enum ReflectionValidationError: Error {
    case secretLeak
  }

  func reflectionMessages(carrier: String) -> [ChatMessage] {
    [
      ChatMessage(role: .system, content: ReflectorPrompt.v1.text),
      ChatMessage(role: .user, content: carrier),
    ]
  }
}
