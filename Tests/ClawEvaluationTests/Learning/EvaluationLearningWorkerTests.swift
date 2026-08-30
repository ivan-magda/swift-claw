import ClawCore
import ClawTestSupport
import Foundation
import Synchronization
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
    let credentialRoot = try makeEvaluationCredentialStateRoot(under: fixture.root)
    let resourceCredentialRoot = Mutex<URL?>(nil)
    let provider = SequenceProvider(scriptedTwoRoundResponses())

    // when
    let result = try await EvaluationWorker().runResult(
      invocation: fixture.invocation,
      credentialStateRoot: credentialRoot.path,
      admissionVerifier: verifier,
      makeResource: { _, suppliedCredentialRoot in
        resourceCredentialRoot.withLock { $0 = suppliedCredentialRoot }
        return makeEvaluationLearningLiveResource(provider: provider)
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
    #expect(resourceCredentialRoot.withLock { $0 } == credentialRoot)
  }

  @Test(arguments: LearningTaskCapMutation.allCases)
  func workerBindsEveryScheduledCapBeforeResourceConstruction(
    mutation: LearningTaskCapMutation
  ) async throws {
    // given
    let fixture = try makeEvaluationLearningTaskInvocationFixture()
    defer { fixture.remove() }
    let invocation = mutation.apply(to: fixture.invocation)
    let resourceCalls = Mutex(0)

    // when
    let error = await #expect(throws: EvaluationWorkerInvocationError.invalidBudgetSnapshot) {
      _ = try await EvaluationWorker().runResult(
        invocation: invocation,
        credentialStateRoot: fixture.root.path,
        admissionVerifier: StaticEvaluationLearningTaskAdmissionVerifier(
          context: fixture.admissionContext
        ),
        makeResource: { _, _ in
          resourceCalls.withLock { $0 += 1 }
          throw LearningWorkerSentinel.unexpectedResourceConstruction
        }
      )
    }

    // then
    #expect(error != nil)
    #expect(resourceCalls.withLock { $0 } == 0)
  }
}

private enum LearningWorkerSentinel: Error {
  case unexpectedResourceConstruction
}

enum LearningTaskCapMutation: CaseIterable, Equatable, Sendable {
  case stageAccountedTokenThreshold
  case globalAccountedTokenThreshold
  case stageResponsesSendCap
  case globalResponsesSendCap

  func apply(to invocation: EvaluationLearningTaskInvocation) -> EvaluationLearningTaskInvocation {
    let budget = invocation.budget
    let changed = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: budget.stageAccountedTokens,
      globalAccountedTokens: budget.globalAccountedTokens,
      stageResponsesSends: budget.stageResponsesSends,
      globalResponsesSends: budget.globalResponsesSends,
      stageAccountedTokenThreshold: budget.stageAccountedTokenThreshold
        - (self == .stageAccountedTokenThreshold ? 1 : 0),
      globalAccountedTokenThreshold: budget.globalAccountedTokenThreshold
        - (self == .globalAccountedTokenThreshold ? 1 : 0),
      stageResponsesSendCap: budget.stageResponsesSendCap
        - (self == .stageResponsesSendCap ? 1 : 0),
      globalResponsesSendCap: budget.globalResponsesSendCap
        - (self == .globalResponsesSendCap ? 1 : 0)
    )
    return EvaluationLearningTaskInvocation(
      schemaVersion: invocation.schemaVersion,
      executionProfile: invocation.executionProfile,
      jobID: invocation.jobID,
      operationID: invocation.operationID,
      attemptGeneration: invocation.attemptGeneration,
      providerCallID: invocation.providerCallID,
      configurationPath: invocation.configurationPath,
      configurationSHA256: invocation.configurationSHA256,
      manifest: invocation.manifest,
      budget: changed,
      authorization: invocation.authorization
    )
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
