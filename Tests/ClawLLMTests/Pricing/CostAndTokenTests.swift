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

  struct ResolveCase: CustomTestStringConvertible, Sendable {
    let name: String
    let model: String
    let prices: [String: ModelPrice]
    let usage: ChatUsage
    let expectedCostUSD: Double
    let tolerance: Double
    let expectedSource: CostSource
    let expectedIsEstimated: Bool

    var testDescription: String { name }
  }

  static let resolveCases: [ResolveCase] = [
    ResolveCase(
      name: "price-file source",
      model: "gpt-4o",
      prices: ["gpt-4o": ModelPrice(inputUSDPerMTok: 2.5, outputUSDPerMTok: 10.0)],
      usage: ChatUsage(
        promptTokens: 1_000_000,
        completionTokens: 1_000_000,
        totalTokens: 2_000_000
      ),
      expectedCostUSD: 12.5,
      tolerance: 1e-9,
      expectedSource: .priceFile,
      expectedIsEstimated: false
    ),
    ResolveCase(
      name: "heuristic — unknown model",
      model: "mystery-model",
      prices: [:],
      usage: ChatUsage(promptTokens: 600, completionTokens: 400, totalTokens: 1000),
      expectedCostUSD: 0.015,
      tolerance: 1e-9,
      expectedSource: .heuristic,
      expectedIsEstimated: true
    ),
    ResolveCase(
      name: "heuristic floor — absent usage",
      model: "mystery-model",
      prices: [:],
      usage: .zero,
      expectedCostUSD: CostResolver.heuristicFloorUSD,
      tolerance: 0,
      expectedSource: .heuristic,
      expectedIsEstimated: true
    ),
  ]

  @Test(arguments: resolveCases)
  func resolveWithNoProviderCost(_ testCase: ResolveCase) {
    // given
    let resolver = resolver(testCase.prices)

    // when
    let resolved = resolver.resolve(
      model: testCase.model,
      usage: testCase.usage,
      providerCost: nil
    )

    // then
    #expect(abs(resolved.costUSD - testCase.expectedCostUSD) <= testCase.tolerance)
    #expect(resolved.source == testCase.expectedSource)
    #expect(resolved.isEstimated == testCase.expectedIsEstimated)
  }

  @Test func tokenEstimateMatchesTheFormula() {
    // given — 8 graphemes; double-ceil → ceil(ceil(8/4) * 1.25) = 3 input tokens
    let messages = [ChatMessage(role: .user, content: "abcdefgh")]

    // then
    #expect(TokenEstimator.estimateInputTokens(messages) == 3)
    #expect(TokenEstimator.graphemeBudget(forInputTokens: 3) == 8)
  }
}
