import ClawCore
import Foundation
import Testing

@testable import ClawData
@testable import ClawGateway

@Suite struct ReflectionOperationRunnerTests {
  @Test func oneTriggerMakesOneFreshToolFreeCallAndAdmitsTheCurrentArtifact() async throws {
    // given
    let env = try ReflectionRunEnvironment.make()

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — omitting automatic admission or replay fencing loses/duplicates the live experiment
    let requests = await env.provider.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.tools.isEmpty)
    #expect(request.maxOutputTokens == 768)
    #expect(request.messages.count == 2)
    #expect(request.messages.map(\.role) == [.system, .user])
    #expect(try env.rowCount("learning_candidates") == 1)
    #expect(try env.rowCount("learning_trials") == 1)
    #expect(try env.rowCount("learning_decisions") == 1)
    #expect(try env.operationState() == .succeeded)
  }

  @Test func exactRenderedRequestBytesBindAuthorizationAndManifest() async throws {
    // given
    let env = try ReflectionRunEnvironment.make()

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — re-rendering any hop would replace nonce-bearing bytes under the saved digest
    let request = try #require(await env.provider.requests.first)
    let user = try #require(request.messages.last?.content.text)
    let keys = try topLevelKeys(user)
    #expect(
      keys == ["evaluations", "issue_codes", "owner_payloads", "schema_version", "stable_lessons"]
    )
    #expect(user.contains("provider_state") == false)
    #expect(user.contains("owner_user_id") == false)
    let expected = CarrierDigest(rawValue: SHA256Digest.hex(Data(user.utf8)))
    #expect(try env.operationCarrierDigest() == expected)
    #expect(try env.candidate()?.manifest.carrierDigest == expected)
  }

  @Test func reflectionUsesRosterFailoverWithoutChangingLogicalCallIdentity() async throws {
    // given
    let env = try ReflectionRunEnvironment.make(
      primaryFailure: ProviderError.quotaLimited(retryAfterSeconds: nil)
    )

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — terminating after the primary or rebuilding nonce-bearing carrier bytes would either
    // lose the candidate or turn one logical reflection into two different calls
    let primary = try #require(await env.provider.requests.first)
    let fallback = try #require(await env.fallbackProvider.requests.first)
    #expect(primary.messages == fallback.messages)
    #expect(primary.tools == fallback.tools)
    #expect(primary.maxOutputTokens == fallback.maxOutputTokens)
    #expect(env.callIDs.count == 1)
    let user = try #require(primary.messages.last?.content.text)
    let expected = CarrierDigest(rawValue: SHA256Digest.hex(Data(user.utf8)))
    #expect(try env.reflectorOperationCount() == 1)
    #expect(
      try env.operationProviderCallID()
        == ProviderCallID(rawValue: "reflection-call-1")
    )
    #expect(try env.operationCarrierDigest() == expected)
    #expect(try env.candidate()?.manifest.operationId == env.reflectorOperationId())
    #expect(try env.candidate()?.manifest.carrierDigest == expected)
    #expect(try env.reflectionUsageModel() == ReflectionRunEnvironment.fallbackRoute)
  }

  @Test func nullCandidateClosesWithAReceiptAndNeverRetries() async throws {
    // given
    let env = try ReflectionRunEnvironment.make(
      reply: #"{"schema_version":1,"candidate":null}"#
    )

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — treating null as a failed or empty candidate would omit or misclassify the receipt
    #expect(await env.provider.requests.count == 1)
    #expect(try env.operationState() == .succeeded)
    #expect(try env.rowCount("learning_decisions") == 1)
    #expect(try env.rowCount("learning_candidates") == 0)
  }

  @Test func emptyReplacementRemainsACandidateRatherThanNoCandidate() async throws {
    // given — empty equals the initial stable lesson set but remains valid output until Task 13
    let env = try ReflectionRunEnvironment.make(
      reply: #"{"schema_version":1,"candidate":{"lessons":[]}}"#
    )

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — collapsing empty with null would write the no-candidate decision instead
    #expect(try env.operationState() == .succeeded)
    #expect(try env.candidate()?.replacement.lessons == [])
    #expect(try env.rowCount("learning_candidates") == 1)
    #expect(try env.rowCount("learning_decisions") == 0)
  }

  @Test func schemaInvalidReplyFailsWithoutARepairCallOrArtifact() async throws {
    // given — the nested candidate contains an unknown field
    let env = try ReflectionRunEnvironment.make(
      reply: #"{"schema_version":1,"candidate":{"lessons":[],"extra":true}}"#
    )

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — a semantic/schema repair loop would make a second paid call for a completed generation
    #expect(await env.provider.requests.count == 1)
    #expect(try env.operationState() == .failed)
    #expect(try env.failureCode() == .schemaInvalid)
    #expect(try env.rowCount("learning_candidates") == 0)
    #expect(try env.rowCount("learning_decisions") == 0)
  }

  @Test func exactCarrierNeedingRedactionIsDeniedBeforeTheNetwork() async throws {
    // given
    let secret = "secret-in-evidence-41"
    let env = try ReflectionRunEnvironment.make(
      finalOutput: "The result contained \(secret)",
      secretValues: [secret]
    )

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — sending a scrubbed reconstruction would break the authorized carrier identity
    #expect(await env.provider.requests.isEmpty)
    #expect(try env.operationState() == .failedNoCall)
    #expect(try env.failureCode() == .carrierPolicyDenied)
  }

  @Test func candidateSecretLeakFailsAfterOneCallWithoutPersistingBytes() async throws {
    // given
    let secret = "secret-in-candidate-99"
    let env = try ReflectionRunEnvironment.make(
      reply: """
        {"schema_version":1,"candidate":{"lessons":["Keep \(secret)"]}}
        """,
      secretValues: [secret]
    )

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — checking only the outbound carrier would persist a newly generated secret verbatim
    #expect(await env.provider.requests.count == 1)
    #expect(try env.operationState() == .failed)
    #expect(try env.failureCode() == .schemaInvalid)
    #expect(try env.rowCount("learning_candidates") == 0)
  }

  @Test(arguments: JSONEscapedSecret.allCases)
  func candidateSecretWithJSONEscapingNeverPersists(_ escaped: JSONEscapedSecret) async throws {
    // given
    let secret = escaped.value
    let env = try ReflectionRunEnvironment.make(
      reply: try candidateReply(lesson: "Keep \(secret) out of durable lessons."),
      secretValues: [secret]
    )

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — scanning only JSON-encoded bytes misses secrets whose quote, slash, or newline is
    // escaped; the paid call still closes and charges without persisting candidate or lesson bytes
    #expect(await env.provider.requests.count == 1)
    #expect(try env.operationState() == .failed)
    #expect(try env.failureCode() == .schemaInvalid)
    #expect(try env.reflectionUsageCount() == 1)
    #expect(try env.rowCount("learning_candidates") == 0)
    #expect(try env.reflectorLessonSetCount() == 0)
  }

  @Test func unavailableLearningBudgetRefusesTheCall() async throws {
    // given — the two source runs already consumed the zero proactive allowance
    let env = try ReflectionRunEnvironment.make(proactivePerDayUSD: 0)

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — dispatching after the transactional denial would overspend the shared proactive pool
    #expect(await env.provider.requests.isEmpty)
    #expect(try env.operationState() == .failedNoCall)
    #expect(try env.failureCode() == .budgetDenied)
  }

  @Test func cancelledAndOneShotJobsNeverReachTheReflectionNetwork() async throws {
    // given
    let cancelled = try ReflectionRunEnvironment.make()
    try cancelled.cancelJob()
    let oneShot = try ReflectionRunEnvironment.make(repeatable: false)

    // when
    await cancelled.runner.runReflection(trigger: cancelled.trigger, now: cancelled.now)
    await oneShot.runner.runReflection(trigger: oneShot.trigger, now: oneShot.now)

    // then — checking only claim eligibility would spend on jobs reflection cannot change safely
    #expect(await cancelled.provider.requests.isEmpty)
    #expect(await oneShot.provider.requests.isEmpty)
    #expect(try cancelled.reflectorOperationCount() == 0)
    #expect(try oneShot.reflectorOperationCount() == 0)
  }

  @Test func liveTrialAndHardVetoNeverReachTheReflectionNetwork() async throws {
    // given — each source otherwise supports the same recurring-issue trigger
    let liveTrial = try ReflectionRunEnvironment.make()
    try liveTrial.openLiveTrialWithoutPointer()
    let vetoed = try ReflectionRunEnvironment.make()
    let vetoedTrigger = try vetoed.hardVetoedTrigger()

    // when
    await liveTrial.runner.runReflection(trigger: liveTrial.trigger, now: liveTrial.now)
    await vetoed.runner.runReflection(trigger: vetoedTrigger, now: vetoed.now)

    // then — omitting either preparation gate would expose one additional network request
    #expect(await liveTrial.provider.requests.isEmpty)
    #expect(await vetoed.provider.requests.isEmpty)
    #expect(try liveTrial.reflectorOperationCount() == 0)
    #expect(try vetoed.reflectorOperationCount() == 0)
  }

  @Test func admissionFailureAfterDurableFinishNeverRepeatsTheProviderCall() async throws {
    // given
    let env = try ReflectionRunEnvironment.make(admissionFails: true)

    // when
    await env.runner.runReflection(trigger: env.trigger, now: env.now)
    await env.runner.runReflection(trigger: env.trigger, now: env.now)

    // then — coupling admission to the finish error path can misreport or retry a paid reflection
    // even though its operation, usage, and candidate already committed durably.
    #expect(await env.provider.requests.count == 1)
    #expect(try env.operationState() == .succeeded)
    #expect(try env.reflectionUsageCount() == 1)
    #expect(try env.rowCount("learning_candidates") == 1)
    #expect(try env.rowCount("learning_trials") == 0)
    #expect(try env.rowCount("learning_decisions") == 0)
    #expect(env.runnerLearning.admissionAttempts == 1)
  }
}

// MARK: - JSON Reads

private extension ReflectionOperationRunnerTests {
  func topLevelKeys(_ json: String) throws -> [String] {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    guard let dictionary = object as? [String: Any] else {
      throw StoreError.unexpected("reflector carrier was not an object")
    }
    return dictionary.keys.sorted()
  }

  func candidateReply(lesson: String) throws -> String {
    let object: [String: Any] = [
      "schema_version": 1,
      "candidate": ["lessons": [lesson]],
    ]
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let reply = String(data: bytes, encoding: .utf8) else {
      throw StoreError.unexpected("candidate reply was not UTF-8")
    }
    return reply
  }
}

enum JSONEscapedSecret: CaseIterable, Sendable {
  case quote
  case backslash
  case newline

  var value: String {
    switch self {
    case .quote:
      "secret\"quoted"
    case .backslash:
      "secret\\backslash"
    case .newline:
      "secret\nnewline"
    }
  }
}
