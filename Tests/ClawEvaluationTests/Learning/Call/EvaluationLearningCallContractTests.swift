import ClawCore
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationLearningCallContractTests {
  @Test(arguments: [
    EvaluationLearningOperationKind.evaluator,
    EvaluationLearningOperationKind.reflector,
  ])
  func requestLoadsOnlyTheTwoCallKindsAndHashesTheCanonicalCore(
    _ kind: EvaluationLearningOperationKind
  ) throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture(kind: kind)
    defer { fixture.remove() }
    try EvaluationCanonicalJSON.data(encoding: fixture.request).write(to: fixture.requestURL)
    let expectedCore = try expectedCoreData(for: fixture.request)

    // when
    let loaded = try EvaluationLearningCallRequest.load(from: fixture.requestURL)

    // then
    #expect(loaded == fixture.request)
    #expect(try EvaluationCanonicalJSON.data(encoding: loaded.core) == expectedCore)
    #expect(loaded.core.sha256 == SHA256Digest.hex(expectedCore))
    #expect(String(bytes: expectedCore, encoding: .utf8)?.contains("authorization") == false)
  }

  @Test func requestRejectsThePrimaryEvaluatorIdentityLeak() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    var object = try jsonObject(encoding: fixture.request)
    object["candidate_identity"] = "candidate-01"
    try EvaluationCanonicalJSON.data(fromJSONObject: object).write(to: fixture.requestURL)

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidJSON) {
      _ = try EvaluationLearningCallRequest.load(from: fixture.requestURL)
    }

    // then
    #expect(error != nil)
  }

  @Test(arguments: UnknownNestedCallRequestField.allCases)
  func requestRejectsAnUnknownFieldInEachClosedNestedObject(
    _ field: UnknownNestedCallRequestField
  ) throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    var object = try jsonObject(encoding: fixture.request)
    try field.addUnknownKey(to: &object)
    try EvaluationCanonicalJSON.data(fromJSONObject: object).write(to: fixture.requestURL)

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidJSON) {
      _ = try EvaluationLearningCallRequest.load(from: fixture.requestURL)
    }

    // then
    #expect(error != nil)
  }

  @Test func resultRejectsARequestDigestFromDifferentCanonicalBytes() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let usage = try EvaluationLearningCallUsage(
      providerCallID: fixture.request.providerCallID,
      responsesSends: 1,
      provenNotStartedResponsesSends: 0,
      terminalUsage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
      missingUsageTokenProxy: fixture.context.missingUsageTokenProxy
    )

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidBinding) {
      _ = try EvaluationLearningCallResult(
        request: fixture.request,
        requestSHA256: String(repeating: "0", count: 64),
        outcome: .response,
        failureCode: nil,
        output: #"{"schema_version":1}"#,
        finishReason: "stop",
        reportedModel: fixture.context.route.wireModel,
        usage: usage,
        admissionContext: fixture.context
      )
    }

    // then
    #expect(error != nil)
  }

  @Test(arguments: InvalidCallRequestMutation.allCases)
  func requestRejectsEachForbiddenKindOrPathMutation(
    _ mutation: InvalidCallRequestMutation
  ) throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture(mutation: mutation)
    defer { fixture.remove() }

    // when
    let error = #expect(throws: (any Error).self) {
      try fixture.request.validate()
    }

    // then
    #expect(error != nil)
  }

  @Test func responseFreezesIdentityAndAccountsEveryLogicalCallSend() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let requestSHA256 = try canonicalRequestSHA256(for: fixture.request)
    let usage = try EvaluationLearningCallUsage(
      providerCallID: fixture.request.providerCallID,
      responsesSends: 2,
      provenNotStartedResponsesSends: 0,
      terminalUsage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
      missingUsageTokenProxy: fixture.context.missingUsageTokenProxy
    )

    // when
    let result = try EvaluationLearningCallResult(
      request: fixture.request,
      requestSHA256: requestSHA256,
      outcome: .response,
      failureCode: nil,
      output: #"{"schema_version":1}"#,
      finishReason: "stop",
      reportedModel: fixture.context.route.wireModel,
      usage: usage,
      admissionContext: fixture.context
    )
    let encoded = try EvaluationCanonicalJSON.data(encoding: result)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let usageObject = try #require(object["usage"] as? [String: Any])
    let provenanceObject = try #require(object["provenance"] as? [String: Any])

    // then
    #expect(result.providerCallID == fixture.request.providerCallID)
    #expect(result.usage?.providerCallID == fixture.request.providerCallID)
    #expect(result.retryBudget == fixture.context.route.retryBudget)
    #expect(result.maxOutputTokens == fixture.context.route.maxOutputTokens)
    #expect(result.maxOutputUTF8Bytes == fixture.context.route.maxOutputUTF8Bytes)
    #expect(result.maxOutputGraphemes == fixture.context.route.maxOutputGraphemes)
    #expect(result.provenance.requestSHA256 == requestSHA256)
    #expect(result.provenance.manifestSHA256 == fixture.context.manifestSHA256)
    #expect(result.provenance.freezeCommit == fixture.context.freezeCommit)
    #expect(result.provenance.executableSHA256 == fixture.context.executableSHA256)
    #expect(result.provenance.promptSHA256 == fixture.request.prompt.sha256)
    #expect(result.provenance.carrierSHA256 == fixture.request.carrier.sha256)
    #expect(result.outputSHA256 == result.output.map { SHA256Digest.hex(Data($0.utf8)) })
    #expect(result.usage?.accountedTokens == 115)
    #expect(result.usage?.isEstimated == true)
    #expect(Set(object.keys) == expectedResultWireKeys)
    #expect(Set(usageObject.keys) == expectedUsageWireKeys)
    #expect(
      Set(provenanceObject.keys)
        == [
          "request_sha256", "manifest_sha256", "freeze_commit", "executable_sha256",
          "prompt_sha256", "carrier_sha256",
        ]
    )
  }

  @Test func failedNoCallIsTheOnlyTerminalShapeWithoutUsage() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }

    // when
    let result = try EvaluationLearningCallResult(
      request: fixture.request,
      requestSHA256: try canonicalRequestSHA256(for: fixture.request),
      outcome: .failedNoCall,
      failureCode: .budgetStopped,
      output: nil,
      finishReason: nil,
      reportedModel: nil,
      usage: nil,
      admissionContext: fixture.context
    )

    // then
    #expect(result.outcome == .failedNoCall)
    #expect(result.failureCode == EvaluationAttemptOutcome.budgetStopped.rawValue)
    #expect(result.usage == nil)
    #expect(result.output == nil)
    #expect(result.outputSHA256 == nil)
  }

  @Test func resultRejectsUsageFromAnotherLogicalProviderCall() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let usage = try EvaluationLearningCallUsage(
      providerCallID: ProviderCallID(
        rawValue: "00000000-0000-0000-0000-000000000099"
      ),
      responsesSends: 1,
      provenNotStartedResponsesSends: 0,
      terminalUsage: nil,
      missingUsageTokenProxy: fixture.context.missingUsageTokenProxy
    )

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidBinding) {
      _ = try EvaluationLearningCallResult(
        request: fixture.request,
        requestSHA256: try canonicalRequestSHA256(for: fixture.request),
        outcome: .failed,
        failureCode: .providerFailure,
        output: nil,
        finishReason: nil,
        reportedModel: nil,
        usage: usage,
        admissionContext: fixture.context
      )
    }

    // then
    #expect(error != nil)
  }

  @Test(arguments: InvalidCallResultMutation.allCases)
  func resultRejectsEachInvalidTerminalShapeOrAccountingMutation(
    _ mutation: InvalidCallResultMutation
  ) throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let candidate = try mutation.candidate(fixture: fixture)

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidBinding) {
      try candidate.validate(missingUsageTokenProxy: fixture.context.missingUsageTokenProxy)
    }

    // then
    #expect(error != nil)
  }

  @Test func resultRejectsAOneTokenProviderBodyAsAFailureCode() throws {
    // given
    let fixture = try makeEvaluationLearningCallFixture()
    defer { fixture.remove() }
    let result = try EvaluationLearningCallResult(
      request: fixture.request,
      requestSHA256: try canonicalRequestSHA256(for: fixture.request),
      outcome: .failedNoCall,
      failureCode: .providerFailure,
      output: nil,
      finishReason: nil,
      reportedModel: nil,
      usage: nil,
      admissionContext: fixture.context
    )
    var object = try jsonObject(encoding: result)
    object["failure_code"] = "unauthorized"
    let decoded = try JSONDecoder().decode(
      EvaluationLearningCallResult.self,
      from: EvaluationCanonicalJSON.data(fromJSONObject: object)
    )

    // when
    let error = #expect(throws: EvaluationLearningAdmissionError.invalidBinding) {
      try decoded.validate(missingUsageTokenProxy: fixture.context.missingUsageTokenProxy)
    }

    // then
    #expect(error != nil)
  }
}
