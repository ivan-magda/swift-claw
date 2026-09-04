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
    let key = reflectionKey(for: trigger)
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
      operationId: claim.id,
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
    let estimate = reflectionAccountant(for: route.binding).preflightEstimate(
      context: call.messages
    )
    let authorization = LearningAuthorization(
      operationId: call.operationId,
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
      logger.info("reflection \(call.operationId.rawValue) refused: \(failure.rawValue)")
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
    var active = starting
    var request = reflectionRequest(model: active.binding.wireModel, messages: call.messages)
    while true {
      do {
        let response = try await active.binding.provider.complete(request: request)
        if active.position == .primary {
          _ = await cooldown?.recordSuccess()
        }
        commitReflection(
          response,
          call: call,
          preparation: preparation,
          route: active.binding,
          now: now
        )
        return
      } catch {
        guard
          let persistence = RouteSwitch.permits(error),
          let next = roster.failover(from: active.position)
        else {
          commitReflection(failure: error, call: call, route: active.binding, now: now)
          return
        }
        await cooldown?.arm(
          persistence: persistence,
          retryAfterSeconds: RouteSwitch.retryAfterSeconds(of: error)
        )
        active = next
        request = reflectionRequest(model: active.binding.wireModel, messages: call.messages)
      }
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
    let usage = LearningCallUsage(
      model: route.configuredReference,
      resolved: reflectionAccountant(for: route).reconciled(for: response, context: call.messages)
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
      logger.info("reflection \(call.operationId.rawValue) returned an unusable reply: \(error)")
      finishReflection(call, usage: usage, product: .failure(.schemaInvalid), now: now)
      return
    }
    finishReflection(call, usage: usage, product: product, now: now)
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
        operationId: call.operationId,
        carrierDigest: call.carrierDigest,
        resultDigest: resultDigest,
        authorization: call.authorization
      )
      return .noCandidate(result)
    }
    let replacement = try LessonSet.canonical(
      jobId: preparation.trigger.jobId,
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
      jobId: preparation.trigger.jobId,
      epoch: preparation.trigger.epoch,
      triggerDigest: preparation.trigger.digest,
      triggerReason: preparation.trigger.reason,
      qualifyingIssueCodes: preparation.trigger.issueCodes,
      operationId: call.operationId,
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

  func commitReflection(
    failure error: any Error,
    call: ReflectionCall,
    route: LLMRouteBinding,
    now: Date
  ) {
    let usage: LearningCallUsage
    switch ProviderFailureAccounting.classify(error) {
    case .mayHaveStarted(let observedCompletionTokens):
      usage = LearningCallUsage(
        model: route.configuredReference,
        resolved: reflectionAccountant(for: route).conservative(
          context: call.messages,
          observedCompletionTokens: observedCompletionTokens
        )
      )
    case .notStarted:
      usage = LearningCallUsage(
        model: route.configuredReference,
        promptTokens: 0,
        completionTokens: 0,
        costUSD: 0,
        costSource: .providerReturned,
        isEstimated: false
      )
    }
    logger.info("reflection \(call.operationId.rawValue) failed at the provider: \(error)")
    finishReflection(call, usage: usage, product: .failure(.providerTerminal), now: now)
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
        LearningOperationResult(operationId: call.operationId, usage: usage, product: product),
        now: now
      )
    } catch {
      logger.error("reflection \(call.operationId.rawValue) could not be committed: \(error)")
      return
    }
    guard committed, case .candidate(let artifact) = product else {
      return
    }
    do {
      _ = try learning.admitCandidate(digest: artifact.digest, redactor: redactor, now: now)
    } catch {
      logger.error("reflection \(call.operationId.rawValue) admission was deferred: \(error)")
    }
  }
}

// MARK: - Reflection Call Shapes

private extension LearningOperationRunner {
  struct ReflectionCall {
    let operationId: LearningOperationID
    let callID: ProviderCallID
    let carrierDigest: CarrierDigest
    let authorization: ReflectionAuthorization
    let messages: [ChatMessage]
  }

  enum ReflectionValidationError: Error {
    case secretLeak
  }

  func reflectionKey(for trigger: TriggerIdentity) -> LearningOperationKey {
    LearningOperationKey(
      jobId: trigger.jobId,
      epoch: trigger.epoch,
      phase: .reflector,
      sourceDigest: trigger.digest.rawValue,
      promptVersion: ReflectorPrompt.v1.version,
      schemaVersion: ReflectorOutput.currentSchemaVersion,
      rubricVersion: ReflectorRubric.v1
    )
  }

  func reflectionMessages(carrier: String) -> [ChatMessage] {
    [
      ChatMessage(role: .system, content: ReflectorPrompt.v1.text),
      ChatMessage(role: .user, content: carrier),
    ]
  }

  func reflectionRequest(model: String, messages: [ChatMessage]) -> ChatRequest {
    ChatRequest(
      model: model,
      messages: messages,
      maxOutputTokens: Self.reflectorOutputTokenCap,
      tools: []
    )
  }

  func reflectionAccountant(for route: LLMRouteBinding) -> ProviderUsageAccountant {
    ProviderUsageAccountant(
      configuredReference: route.configuredReference,
      costPolicy: route.costPolicy,
      reservationPolicy: route.reservationPolicy,
      costResolver: costResolver,
      outputCap: Self.reflectorOutputTokenCap
    )
  }
}
