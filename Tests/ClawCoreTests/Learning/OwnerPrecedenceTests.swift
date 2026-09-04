import ClawCore
import Foundation
import Testing

@Suite struct OwnerPrecedenceTests {
  @Test func eachPrecedenceRungWinsOverTheOneBelow() {
    // given
    let evaluator = EvaluatorOutcome.reusableIssue
    let codes = ["material.missed"]

    // when
    let bare = OwnerPrecedence.resolve(evaluator: evaluator, issueCodes: codes, signals: [])
    let confirmed = OwnerPrecedence.resolve(
      evaluator: evaluator,
      issueCodes: codes,
      signals: [event(.evaluationConfirm)]
    )
    let useful = OwnerPrecedence.resolve(
      evaluator: evaluator,
      issueCodes: codes,
      signals: [event(.evaluationConfirm), event(.resultUseful, revision: 2)]
    )

    // then
    #expect(bare.outcome == .negative(issueCodes: codes))
    #expect(bare.ownerConfirmed == false)
    #expect(confirmed.outcome == .negative(issueCodes: codes))
    #expect(confirmed.ownerConfirmed)
    #expect(useful.outcome == .positive)
    #expect(useful.ownerConfirmed == false)
  }

  @Test func latestResultSignalWins() {
    // given
    let useful = event(.resultUseful, id: 1, revision: 1)
    let notUseful = event(.resultNotUseful, id: 2, revision: 2)

    // when
    let resolved = OwnerPrecedence.resolve(
      evaluator: .noIssue,
      issueCodes: ["evaluator-code"],
      signals: [useful, notUseful]
    )

    // then
    #expect(resolved.outcome == .negative(issueCodes: ["evaluator-code"]))
  }

  @Test func supersededResultSignalDoesNotCount() {
    // given
    let useful = event(.resultUseful, id: 1, revision: 1)
    let notUseful = event(.resultNotUseful, id: 2, revision: 2)
    let confirmation = event(.evaluationConfirm, id: 3, revision: 3, supersedes: 2)

    // when
    let resolved = OwnerPrecedence.resolve(
      evaluator: .reusableIssue,
      issueCodes: ["evaluator-code"],
      signals: [useful, notUseful, confirmation]
    )

    // then
    #expect(resolved.outcome == .positive)
    #expect(resolved.ownerConfirmed == false)
  }

  @Test(
    arguments: [
      (EvaluatorOutcome.noIssue, EffectiveOutcome.positive),
      (.reusableIssue, .negative(issueCodes: ["evaluator-code"])),
      (.transientIssue, .neutral),
      (.uncertain, .neutral),
    ]
  )
  func everyEvaluatorOutcomeMapsToItsEffectiveOutcome(
    evaluator: EvaluatorOutcome,
    expected: EffectiveOutcome
  ) {
    // given / when
    let resolved = OwnerPrecedence.resolve(
      evaluator: evaluator,
      issueCodes: ["evaluator-code"],
      signals: []
    )

    // then
    #expect(resolved.outcome == expected)
  }

  @Test func notUsefulWithoutEvaluatorCodeUsesSyntheticCode() {
    // given
    let signals = [event(.resultNotUseful)]

    // when
    let resolved = OwnerPrecedence.resolve(evaluator: nil, issueCodes: [], signals: signals)

    // then
    let expected = [OwnerPrecedence.syntheticNotUsefulCode]
    #expect(resolved.outcome == .negative(issueCodes: expected))
  }

  @Test func correctionWithoutEvaluatorCodeDoesNotManufactureCode() {
    // given
    let signals = [event(.resultCorrection)]

    // when
    let resolved = OwnerPrecedence.resolve(evaluator: nil, issueCodes: [], signals: signals)

    // then
    #expect(resolved.outcome == .negative(issueCodes: []))
  }

  @Test func reusableIssueWithoutCodesRemainsStructurallyInert() {
    // given / when
    let resolved = OwnerPrecedence.resolve(
      evaluator: .reusableIssue,
      issueCodes: [],
      signals: []
    )

    // then
    #expect(resolved.outcome == .negative(issueCodes: []))
  }

  @Test func disputeRemovesEvaluatorOutcomeAndVetoesDependentDecisions() {
    // given
    let signals = [event(.evaluationDispute)]

    // when
    let resolved = OwnerPrecedence.resolve(
      evaluator: .noIssue,
      issueCodes: [],
      signals: signals
    )

    // then
    #expect(resolved.outcome == .neutral)
    #expect(resolved.hardVetoes == [.ownerDependencyRejected])
    #expect(resolved.permitsDependentDecision == false)
  }

  @Test func ownerResultRemainsEffectiveWhenEvaluatorIsDisputed() {
    // given
    let signals = [
      event(.evaluationDispute, id: 1, revision: 1),
      event(.resultUseful, id: 2, revision: 2),
    ]

    // when
    let resolved = OwnerPrecedence.resolve(
      evaluator: .reusableIssue,
      issueCodes: ["evaluator-code"],
      signals: signals
    )

    // then — treating every dispute as an unconditional veto would erase independent run feedback
    #expect(resolved.outcome == .positive)
    #expect(resolved.evaluationRequired == false)
    #expect(resolved.hardVetoes.isEmpty)
    #expect(resolved.permitsDependentDecision)
  }

  @Test(arguments: HardVeto.allCases)
  func eachHardVetoOutranksAPositiveOutcome(veto: HardVeto) {
    // given / when
    let resolved = OwnerPrecedence.resolve(
      evaluator: .noIssue,
      issueCodes: [],
      signals: [],
      hardVetoes: [veto]
    )

    // then
    #expect(resolved.outcome == .positive)
    #expect(resolved.hardVetoes == [veto])
    #expect(resolved.permitsDependentDecision == false)
  }
}

// MARK: - Fixtures

private func event(
  _ signal: OwnerSignal,
  id: Int64 = 1,
  revision: Int64 = 1,
  supersedes: Int64? = nil
) -> FeedbackEvent {
  FeedbackEvent(
    id: id,
    runId: 41,
    signal: signal,
    payload: nil,
    revision: FeedbackRevision(revision),
    supersedes: supersedes,
    occurredAt: Date(timeIntervalSince1970: TimeInterval(revision))
  )
}
