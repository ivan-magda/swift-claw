import Foundation
import Testing

@testable import ClawCore

@Suite struct CostAndTokenTests {
  private static let referenceUSDPerToken = 0.000_015

  private func resolver(_ prices: [String: ModelPrice] = [:]) -> CostResolver {
    CostResolver(
      priceTable: PriceTable(prices: prices),
      referenceUSDPerToken: Self.referenceUSDPerToken
    )
  }

  @Test func providerCostWinsIncludingConfirmedZero() {
    // given
    let usage = ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15)

    // when — a real cost and a *confirmed* zero both come straight from the provider
    let paid = resolver().resolve(model: "gpt-4o", usage: usage, providerCost: 0.42)
    let free = resolver().resolve(model: "gpt-4o", usage: usage, providerCost: 0.0)

    // then
    #expect(paid == ResolvedCost(costUSD: 0.42, source: .providerReturned, isEstimated: false))
    #expect(free == ResolvedCost(costUSD: 0.0, source: .providerReturned, isEstimated: false))
  }

  @Test func priceFileComputesFromTokensWhenNoProviderCost() {
    // given — gpt-4o at $2.5 in / $10 out per MTok, exactly 1M of each
    let prices = ["gpt-4o": ModelPrice(inputUSDPerMTok: 2.5, outputUSDPerMTok: 10.0)]
    let usage = ChatUsage(
      promptTokens: 1_000_000,
      completionTokens: 1_000_000,
      totalTokens: 2_000_000
    )

    // when
    let resolved = resolver(prices).resolve(model: "gpt-4o", usage: usage, providerCost: nil)

    // then
    #expect(abs(resolved.costUSD - 12.5) < 1e-9)
    #expect(resolved.source == .priceFile)
    #expect(resolved.isEstimated == false)
  }

  @Test func heuristicCarriesUnknownModelAndIsFlaggedEstimated() {
    // given — no price entry; cost falls to the reference-per-token heuristic
    let usage = ChatUsage(promptTokens: 600, completionTokens: 400, totalTokens: 1000)

    // when
    let resolved = resolver().resolve(model: "mystery-model", usage: usage, providerCost: nil)

    // then
    #expect(abs(resolved.costUSD - 0.015) < 1e-9)
    #expect(resolved.source == .heuristic)
    #expect(resolved.isEstimated)
  }

  @Test func absentProviderUsageIsFlooredNotSilentlyZero() {
    // given — provider returned no usage; a guessed cost must never be a silent $0
    let resolved = resolver().resolve(model: "mystery-model", usage: .zero, providerCost: nil)

    // then
    #expect(resolved.costUSD == CostResolver.heuristicFloorUSD)
    #expect(resolved.source == .heuristic)
    #expect(resolved.isEstimated)
  }

  @Test func tokenEstimateMatchesTheFormula() {
    // given — 8 graphemes; double-ceil → ceil(ceil(8/4) * 1.25) = 3 input tokens
    let messages = [ChatMessage(role: .user, content: "abcdefgh")]

    // then
    #expect(TokenEstimator.estimateInputTokens(messages) == 3)
    #expect(TokenEstimator.estimateTotalTokens(messages, maxOutput: 16) == 19)
    #expect(TokenEstimator.graphemeBudget(forInputTokens: 3) == 8)
  }
}
