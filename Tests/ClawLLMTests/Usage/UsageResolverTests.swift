import Foundation
import Testing

@testable import ClawCore

@Suite struct UsageResolverTests {
  private let resolver = UsageResolver()

  @Test func providerReportedUsageWinsAndIsNotEstimated() {
    // given — the provider returned real token counts
    let response = ChatResponse(
      content: "hello",
      finishReason: "stop",
      usage: ChatUsage(promptTokens: 12, completionTokens: 7, totalTokens: 19),
      costFromProvider: nil
    )

    // when
    let resolved = resolver.resolve(
      response: response,
      context: [ChatMessage(role: .user, content: "hi")]
    )

    // then
    #expect(resolved.usage == ChatUsage(promptTokens: 12, completionTokens: 7, totalTokens: 19))
    #expect(resolved.isEstimated == false)
  }

  @Test func omittedUsageIsEstimatedFromContextAndReply() {
    // given — a provider that omits the usage object (some local servers do)
    let response = ChatResponse(
      content: "Hi!",
      finishReason: "stop",
      usage: nil,
      costFromProvider: nil
    )

    // when
    let resolved = resolver.resolve(
      response: response,
      context: [ChatMessage(role: .user, content: "hello world")]
    )

    // then — prompt estimated from context, completion from the reply, flagged estimated
    #expect(resolved.usage.promptTokens == 4)  // "hello world"
    #expect(resolved.usage.completionTokens == 2)  // "Hi!"
    #expect(resolved.usage.totalTokens == 6)
    #expect(resolved.isEstimated == true)
  }

  @Test func noResponseEstimateReservesTheOutputCap() {
    // given/when — a call that produced no response (deadline / exhausted retries)
    let resolved = resolver.estimate(
      context: [ChatMessage(role: .user, content: "hello world")],
      maxOutputTokens: 1024
    )

    // then — prompt from context, completion reserved at the cap, flagged estimated
    #expect(resolved.usage.promptTokens == 4)
    #expect(resolved.usage.completionTokens == 1024)
    #expect(resolved.usage.totalTokens == 4 + 1024)
    #expect(resolved.isEstimated == true)
  }

  @Test func rowIsEstimatedWhenEitherTokensOrCostAreGuessed() {
    // given — the four combinations of token/cost provenance
    let tokens = ChatUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2)
    let realTokens = ResolvedUsage(usage: tokens, isEstimated: false)
    let estTokens = ResolvedUsage(usage: tokens, isEstimated: true)
    let realCost = ResolvedCost(costUSD: 0.01, source: .providerReturned, isEstimated: false)
    let estCost = ResolvedCost(costUSD: 0.01, source: .heuristic, isEstimated: true)

    func row(_ usage: ResolvedUsage, _ cost: ResolvedCost) -> ProviderUsage {
      ProviderUsage(runId: 1, sessionId: 2, model: "m", usage: usage, cost: cost, ts: Date())
    }

    // then — a row is an estimate iff either input was guessed
    #expect(row(realTokens, realCost).isEstimated == false)
    #expect(row(estTokens, realCost).isEstimated == true)
    #expect(row(realTokens, estCost).isEstimated == true)
    #expect(row(estTokens, estCost).isEstimated == true)
  }
}
