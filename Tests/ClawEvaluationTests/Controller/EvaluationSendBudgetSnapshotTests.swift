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
  private static let scheduledBudgets = EvaluationLearningApprovedBudgets(
    taskAttempts: 10,
    evaluatorCalls: 5,
    reflectorCalls: 1,
    responsesSends: 38,
    accountedTokens: 5_045_184
  )

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

  @Test func scheduledLearningValidationAcceptsExactAdmittedCaps() throws {
    // given
    let snapshot = Self.scheduledSnapshot(accountedTokens: 0, responsesSends: 0)

    // when / then
    try snapshot.validateScheduledLearning(approvedBudgets: Self.scheduledBudgets)
  }

  @Test(arguments: ScheduledCapMutation.allCases)
  private func scheduledLearningValidationRejectsAnyChangedAdmittedCap(
    mutation: ScheduledCapMutation
  ) {
    // given
    let snapshot = mutation.apply(
      to: Self.scheduledSnapshot(accountedTokens: 0, responsesSends: 0)
    )

    // when / then
    #expect(throws: EvaluationWorkerInvocationError.invalidBudgetSnapshot) {
      try snapshot.validateScheduledLearning(approvedBudgets: Self.scheduledBudgets)
    }
  }

  @Test func scheduledLearningAdmissionReachesActiveAndRestartBeforeExactExhaustion() {
    // given
    let proxy = PageEvaluationContract.missingUsageTokenProxy
    let empty = ProviderRoundTripAdmissionContext(
      roundTripIndex: 1,
      priorRecordedTokens: 0,
      priorResponsesSends: 0
    )
    let oneMissingUsageSend = ProviderRoundTripAdmissionContext(
      roundTripIndex: 2,
      priorRecordedTokens: proxy,
      priorResponsesSends: 1,
      priorMissingUsageRecordedTokens: proxy,
      priorMissingUsageResponsesSends: 1
    )
    let active = Self.scheduledSnapshot(accountedTokens: 34 * proxy, responsesSends: 34)
    let restart = Self.scheduledSnapshot(accountedTokens: 36 * proxy, responsesSends: 36)

    // when
    let admissions = [
      active.admission(empty),
      active.admission(oneMissingUsageSend),
      restart.admission(empty),
      restart.admission(oneMissingUsageSend),
    ]
    let sendOverflow = Self.scheduledSnapshot(
      accountedTokens: 0,
      responsesSends: 38
    ).admission(empty)
    let tokenOverflow = Self.scheduledSnapshot(
      accountedTokens: Self.scheduledBudgets.accountedTokens,
      responsesSends: 0
    ).admission(empty)

    // then
    #expect(admissions.allSatisfy { $0 == .allow })
    #expect(sendOverflow == .deny(cap: EvaluationSendBudgetSnapshot.stageResponsesSendCapName))
    #expect(tokenOverflow == .deny(cap: EvaluationSendBudgetSnapshot.stageAccountedTokenCap))
  }

  @Test func legacyValidationKeepsProtocolPointSixCaps() throws {
    // given
    let legacy = EvaluationSendBudgetSnapshot(
      stageAccountedTokens: 0,
      globalAccountedTokens: 0,
      stageResponsesSends: 0,
      globalResponsesSends: 0,
      stageAccountedTokenThreshold: Self.pageLimits.accountedTokenThreshold,
      globalAccountedTokenThreshold: 4_350_000,
      stageResponsesSendCap: Self.pageLimits.maximumResponsesSends,
      globalResponsesSendCap: 454
    )
    let scheduled = Self.scheduledSnapshot(accountedTokens: 0, responsesSends: 0)

    // when / then
    try legacy.validate()
    #expect(throws: EvaluationWorkerInvocationError.invalidBudgetSnapshot) {
      try scheduled.validate()
    }
  }

  private static func scheduledSnapshot(
    accountedTokens: Int,
    responsesSends: Int
  ) -> EvaluationSendBudgetSnapshot {
    EvaluationSendBudgetSnapshot(
      stageAccountedTokens: accountedTokens,
      globalAccountedTokens: accountedTokens,
      stageResponsesSends: responsesSends,
      globalResponsesSends: responsesSends,
      stageAccountedTokenThreshold: scheduledBudgets.accountedTokens,
      globalAccountedTokenThreshold: scheduledBudgets.accountedTokens,
      stageResponsesSendCap: scheduledBudgets.responsesSends,
      globalResponsesSendCap: scheduledBudgets.responsesSends
    )
  }
}

private enum ScheduledCapMutation: CaseIterable, Equatable, Sendable {
  case stageAccountedTokenThreshold
  case globalAccountedTokenThreshold
  case stageResponsesSendCap
  case globalResponsesSendCap

  func apply(to snapshot: EvaluationSendBudgetSnapshot) -> EvaluationSendBudgetSnapshot {
    EvaluationSendBudgetSnapshot(
      stageAccountedTokens: snapshot.stageAccountedTokens,
      globalAccountedTokens: snapshot.globalAccountedTokens,
      stageResponsesSends: snapshot.stageResponsesSends,
      globalResponsesSends: snapshot.globalResponsesSends,
      stageAccountedTokenThreshold: snapshot.stageAccountedTokenThreshold
        - (self == .stageAccountedTokenThreshold ? 1 : 0),
      globalAccountedTokenThreshold: snapshot.globalAccountedTokenThreshold
        - (self == .globalAccountedTokenThreshold ? 1 : 0),
      stageResponsesSendCap: snapshot.stageResponsesSendCap
        - (self == .stageResponsesSendCap ? 1 : 0),
      globalResponsesSendCap: snapshot.globalResponsesSendCap
        - (self == .globalResponsesSendCap ? 1 : 0)
    )
  }
}
