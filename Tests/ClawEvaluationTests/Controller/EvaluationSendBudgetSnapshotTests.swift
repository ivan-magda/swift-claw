import ClawAgent
import ClawCore
import Testing

@testable import ClawEvaluation

@Suite struct EvaluationSendBudgetSnapshotTests {
  private struct BoundaryCase: Sendable {
    let stageAccountedTokens: Int
    let globalAccountedTokens: Int
    let stageResponsesSends: Int
    let globalResponsesSends: Int
    let expected: ProviderRoundTripAdmission
  }

  private static let pageLimits = PageEvaluationContract.pageLimits

  private static let boundaryCases = [
    BoundaryCase(
      stageAccountedTokens: pageLimits.accountedTokenThreshold - 1,
      globalAccountedTokens: PageEvaluationContract.globalAccountedTokenThreshold - 1,
      stageResponsesSends: pageLimits.maximumResponsesSends - 1,
      globalResponsesSends: PageEvaluationContract.globalMaximumResponsesSends - 1,
      expected: .allow
    ),
    BoundaryCase(
      stageAccountedTokens: pageLimits.accountedTokenThreshold,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      expected: .deny(cap: EvaluationSendBudgetSnapshot.stageAccountedTokenCap)
    ),
    BoundaryCase(
      stageAccountedTokens: 0,
      globalAccountedTokens: PageEvaluationContract.globalAccountedTokenThreshold,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      expected: .deny(cap: EvaluationSendBudgetSnapshot.globalAccountedTokenCap)
    ),
    BoundaryCase(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: pageLimits.maximumResponsesSends,
      globalResponsesSends: 0,
      expected: .deny(cap: EvaluationSendBudgetSnapshot.stageResponsesSendCapName)
    ),
    BoundaryCase(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: PageEvaluationContract.globalMaximumResponsesSends,
      expected: .deny(cap: EvaluationSendBudgetSnapshot.globalResponsesSendCapName)
    ),
  ]

  @Test(arguments: boundaryCases)
  private func admissionHonorsEveryExactBoundaryAndAllowsValuesBelowThem(
    testCase: BoundaryCase
  ) throws {
    // given
    let snapshot = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: testCase.stageAccountedTokens,
      globalAccountedTokens: testCase.globalAccountedTokens,
      stageResponsesSends: testCase.stageResponsesSends,
      globalResponsesSends: testCase.globalResponsesSends,
      stageAccountedTokenThreshold: Self.pageLimits.accountedTokenThreshold,
      stageResponsesSendCap: Self.pageLimits.maximumResponsesSends
    )
    try snapshot.validate()

    // when
    let admission = snapshot.admission(
      ProviderRoundTripAdmissionContext(
        roundTripIndex: 1,
        priorRecordedTokens: 0,
        priorResponsesSends: 0
      )
    )

    // then
    #expect(admission == testCase.expected)
  }

  @Test func missingUsageProxyCanStopTheSecondSendAtTheStageThreshold() {
    // given — runtime estimation recorded nine tokens, but the provider omitted usage. The fixed
    // proxy reaches the threshold exactly; treating those nine estimated tokens as final would not.
    let limits = PageEvaluationContract.pageLimits
    let snapshot = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: limits.accountedTokenThreshold
        - PageEvaluationContract.missingUsageTokenProxy,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: limits.accountedTokenThreshold,
      stageResponsesSendCap: limits.maximumResponsesSends
    )
    let context = ProviderRoundTripAdmissionContext(
      roundTripIndex: 2,
      priorRecordedTokens: 9,
      priorResponsesSends: 1,
      priorMissingUsageRecordedTokens: 9,
      priorMissingUsageResponsesSends: 1
    )

    // when
    let admission = snapshot.admission(context)

    // then
    #expect(admission == .deny(cap: EvaluationSendBudgetSnapshot.stageAccountedTokenCap))
  }
}
