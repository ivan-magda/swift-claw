import ClawCore
import Foundation
import Testing

/// One row of the reservation table. `payloadByteCounts` describes the history a policy sees: a nil
/// entry is an ordinary message carrying no replay state, so a policy that charges framing per
/// message rather than per state is visibly wrong.
struct ReservationCase: Sendable, CustomTestStringConvertible {
  let scenario: String
  let payloadByteCounts: [Int?]
  let expected: Int

  var testDescription: String { scenario }
}

/// Payload bytes are deliberately invalid UTF-8 and the issuer is a plausible-looking identity, so
/// any policy that tries to read either fails loudly instead of quietly agreeing with the byte math.
private func history(_ payloadByteCounts: [Int?]) -> [ChatMessage] {
  payloadByteCounts.map { byteCount in
    guard let byteCount else {
      return ChatMessage(role: .user, content: "plain")
    }
    return ChatMessage(
      role: .assistant,
      content: "reply",
      providerState: ProviderExchangeState(
        issuer: "openai-chatgpt-responses-v1:profile:model:epoch",
        payload: Data(repeating: 0xFF, count: byteCount)
      )
    )
  }
}

@Suite struct LLMAccountingTests {
  // MARK: - Input Reservation

  /// A cap of 1024 bytes at two tokens each keeps every expectation distinguishable from the two
  /// mutants that matter: capping after multiplication, and not capping at all.
  private static let policy = LLMInputReservationPolicy.replayState(
    tokensPerByte: 2,
    framingTokensPerState: 256,
    aggregateByteCap: 1024
  )

  @Test(arguments: [
    ReservationCase(scenario: "no messages at all", payloadByteCounts: [], expected: 0),
    ReservationCase(
      scenario: "no message carries state",
      payloadByteCounts: [nil, nil],
      expected: 0
    ),
    ReservationCase(scenario: "one state", payloadByteCounts: [10], expected: 276),
    ReservationCase(scenario: "multiple states", payloadByteCounts: [10, 15], expected: 562),
    ReservationCase(
      scenario: "framing is charged per state, not per message",
      payloadByteCounts: [nil, 10, nil],
      expected: 276
    ),
    ReservationCase(
      scenario: "an empty payload costs exactly one framing allowance",
      payloadByteCounts: [0],
      expected: 256
    ),
    ReservationCase(
      scenario: "bytes exactly at the aggregate cap",
      payloadByteCounts: [1024],
      expected: 2304
    ),
    ReservationCase(
      scenario: "aggregate bytes are capped before multiplication",
      payloadByteCounts: [600, 600],
      expected: 2560
    ),
  ])
  func replayStateReservesTwoTokensPerCappedPayloadBytePlusFraming(sample: ReservationCase) {
    // given
    let messages = history(sample.payloadByteCounts)

    // when
    let reserved = Self.policy.additionalTokens(for: messages)

    // then
    #expect(reserved == sample.expected)
  }

  @Test func textOnlyReservesNothingEvenWhenHistoryCarriesState() {
    // given
    let messages = history([4096, 4096])

    // when
    let reserved = LLMInputReservationPolicy.textOnly.additionalTokens(for: messages)

    // then
    #expect(reserved == 0)
  }

  @Test func aPathologicalConfigurationSaturatesInsteadOfOverflowing() {
    // given
    let absurd = LLMInputReservationPolicy.replayState(
      tokensPerByte: .max,
      framingTokensPerState: .max,
      aggregateByteCap: 1024
    )

    // when
    let reserved = absurd.additionalTokens(for: history([8, 8]))

    // then
    #expect(reserved == .max)
  }

  @Test func theChatGPTReservationChargesTwoTokensPerByteAndFramesEachState() {
    // given
    let messages = history([1000])

    // when
    let reserved = LLMInputReservationPolicy.chatGPTReplayState.additionalTokens(for: messages)

    // then
    #expect(reserved == 2256)
  }

  /// Pins the aggregate cap itself: history well past it must reserve the capped budget, because a
  /// cap set too low would under-reserve — the one direction the reservation may not err.
  @Test func theChatGPTReservationCapsAggregateBytesAtFourMebibytes() {
    // given
    let threeMebibytes = 3 * 1024 * 1024
    let messages = history([threeMebibytes, threeMebibytes])

    // when
    let reserved = LLMInputReservationPolicy.chatGPTReplayState.additionalTokens(for: messages)

    // then
    #expect(reserved == 8_389_120)
  }

  @Test func theTextEstimatorNeverAccountsForReplayState() {
    // given
    let bare = [ChatMessage(role: .assistant, content: "reply")]
    let stateful = history([4096])

    // when
    let bareTokens = TokenEstimator.estimateInputTokens(bare)
    let statefulTokens = TokenEstimator.estimateInputTokens(stateful)

    // then
    #expect(statefulTokens == bareTokens)
  }

  // MARK: - Included-Plan Cost

  private static let resolver = CostResolver(
    priceTable: PriceTable(
      prices: ["gpt-5.4-codex": ModelPrice(inputUSDPerMTok: 5, outputUSDPerMTok: 15)]
    ),
    referenceUSDPerToken: 0.000_01
  )

  private static let reportedUsage = ChatUsage(
    promptTokens: 100,
    completionTokens: 50,
    totalTokens: 150
  )

  @Test func theIncludedPlanCostSourceKeepsItsDurableSpelling() {
    // given / when / then
    #expect(CostSource.includedPlan.rawValue == "included_plan")
  }

  @Test func includedPlanConfirmsAZeroCostAndIgnoresProviderReportedDollars() {
    // given
    let policy = LLMCostPolicy.includedPlan

    // when
    let cost = Self.resolver.resolve(
      model: "gpt-5.4-codex",
      usage: Self.reportedUsage,
      providerCost: 1.23,
      policy: policy
    )

    // then
    #expect(cost.costUSD == 0)
    #expect(cost.source == .includedPlan)
    #expect(cost.isEstimated == false)
  }

  @Test func includedPlanOutranksTheVendoredPriceFile() {
    // given
    let policy = LLMCostPolicy.includedPlan

    // when
    let cost = Self.resolver.resolve(
      model: "gpt-5.4-codex",
      usage: Self.reportedUsage,
      providerCost: nil,
      policy: policy
    )

    // then
    #expect(cost.costUSD == 0)
    #expect(cost.source == .includedPlan)
  }

  @Test func meteredStaysTheDefaultPolicy() {
    // given / when
    let cost = Self.resolver.resolve(
      model: "gpt-5.4-codex",
      usage: Self.reportedUsage,
      providerCost: 1.23
    )

    // then
    #expect(cost.source == .providerReturned)
    #expect(cost.costUSD == 1.23)
  }

  @Test func providerReturnedCountsRecordAnIncludedPlanRowAsConfirmed() {
    // given
    let usage = ResolvedUsage(usage: Self.reportedUsage, isEstimated: false)
    let cost = Self.resolver.resolve(
      model: "gpt-5.4-codex",
      usage: usage.usage,
      providerCost: nil,
      policy: .includedPlan
    )

    // when
    let row = ProviderUsage(
      runId: 1,
      sessionId: 2,
      model: "openai-chatgpt/gpt-5.4-codex",
      usage: usage,
      cost: cost,
      ts: Date(timeIntervalSince1970: 0)
    )

    // then
    #expect(row.costUSD == 0)
    #expect(row.costSource == .includedPlan)
    #expect(row.isEstimated == false)
  }

  @Test func missingCountsRecordAnEstimatedIncludedPlanRowWhoseZeroStaysConfirmed() {
    // given
    let usage = UsageResolver().resolve(
      response: ChatResponse(
        content: "hello",
        finishReason: "stop",
        usage: nil,
        costFromProvider: nil
      ),
      context: [ChatMessage(role: .user, content: "hi")]
    )
    let cost = Self.resolver.resolve(
      model: "gpt-5.4-codex",
      usage: usage.usage,
      providerCost: nil,
      policy: .includedPlan
    )

    // when
    let row = ProviderUsage(
      runId: 1,
      sessionId: 2,
      model: "openai-chatgpt/gpt-5.4-codex",
      usage: usage,
      cost: cost,
      ts: Date(timeIntervalSince1970: 0)
    )

    // then
    #expect(row.costUSD == 0)
    #expect(row.costSource == .includedPlan)
    #expect(row.isEstimated)
  }

  // MARK: - Provider Call Identity

  @Test func theLiveGeneratorMintsDistinctLowercaseIdentifiers() {
    // given
    let generator: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator()

    // when
    let minted = (0..<64).map { _ in
      generator.next()
    }

    // then
    #expect(Set(minted).count == minted.count)
    #expect(
      minted.allSatisfy { callID in
        callID.rawValue.isEmpty == false && callID.rawValue == callID.rawValue.lowercased()
      }
    )
  }

  @Test func migrationAndLiveIdentifiersShareOneDomain() {
    // given
    let legacy = ProviderCallID(rawValue: "legacy:42")
    let live = UUIDProviderCallIDGenerator().next()

    // when
    let identifiers: Set<ProviderCallID> = [legacy, live]

    // then
    #expect(identifiers.count == 2)
    #expect(legacy != live)
  }

  // MARK: - Failure Accounting

  @Test(arguments: [(-5, 0), (0, 0), (7, 7)])
  func observedCompletionTokensAreClampedToANonnegativeLowerBound(
    observed: Int,
    expected: Int
  ) {
    // given / when
    let accounting = ProviderFailureAccounting.mayHaveStarted(observing: observed)

    // then
    #expect(accounting == .mayHaveStarted(observedCompletionTokens: expected))
  }
}
