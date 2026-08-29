import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationLearningWorkerTests {
  @Test func m3AttemptCompletesWithoutALegacyJournalOrRunOrder() async throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    let verifier = StaticEvaluationLearningTaskAdmissionVerifier(
      context: fixture.admissionContext
    )
    let provider = SequenceProvider(scriptedTwoRoundResponses())

    // when
    let result = try await EvaluationWorker().runResult(
      invocation: fixture.invocation,
      admissionVerifier: verifier,
      makeResource: { _ in
        makeEvaluationLearningLiveResource(provider: provider)
      }
    )
    let durable = try EvaluationJSONFile.decode(
      EvaluationAttemptResult.self,
      from: fixture.configuration.resultURL
    )

    // then
    #expect(result == durable)
    #expect(result.attemptID == fixture.configuration.attemptID)
    #expect(result.inputSHA256 == fixture.configuration.inputSHA256)
    #expect(result.manifestSHA256 == fixture.invocation.manifest.manifestSHA256)
    #expect(result.provenance.freezeCommit == fixture.admissionContext.freezeCommit)
  }
}

struct StaticEvaluationLearningTaskAdmissionVerifier: EvaluationLearningAdmissionVerifying {
  let context: EvaluationLearningAdmissionContext

  func verify(
    manifest _: EvaluationLearningManifestBinding,
    authorization _: EvaluationLearningOperationAuthorization,
    invocationCoreDigest _: String,
    carrierSHA256 _: String,
    providerCallID _: ProviderCallID,
    kind _: EvaluationLearningOperationKind
  ) async throws -> EvaluationLearningAdmissionContext {
    context
  }
}

func makeEvaluationLearningLiveResource(provider: SequenceProvider) -> EvaluationLiveResource {
  let roster = ProviderRoster(
    primary: LLMRouteBinding(
      provider: provider,
      wireModel: PageEvaluationContract.wireModel,
      configuredReference: PageEvaluationContract.providerReference,
      costPolicy: .includedPlan,
      reservationPolicy: .chatGPTReplayState
    )
  )
  return EvaluationLiveResource(
    roster: roster,
    httpRecorder: EvaluationHTTPRecorder(base: ScriptedHTTPExecutor([])),
    credentialSource: NoopEvaluationLearningCredentialSource(),
    closeTransport: {}
  )
}

private struct NoopEvaluationLearningCredentialSource: LLMCredentialSource {
  func authorization() async throws -> LLMRequestAuthorization {
    LLMRequestAuthorization(headers: [:], redactionValues: [], generation: .zero)
  }

  func reject(
    generation _: LLMCredentialGeneration,
    disposition _: LLMCredentialRejection
  ) async {}

  func shutdown() async throws {}
}
