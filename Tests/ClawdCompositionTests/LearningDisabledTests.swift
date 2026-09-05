import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct LearningDisabledTests {
  @Test func anUnarmedDeploymentCompletesAndDeliversWithoutLearningRows() async throws {
    try await LearningAcceptanceHarness.withHarness(learningEnabled: false) { env in
      // given
      #expect(env.learning == nil)

      // when
      let runId = try await env.fireScheduledRun()
      await env.outbox.drainOnce()

      // then
      #expect(try env.runState(runId) == .done)
      #expect(try env.stores.learning.binding(runId: runId) == nil)
      #expect(try env.learningRowCounts().allSatisfy { $0 == 0 })
      let sent = await env.telegram.recorded.filter { $0.url.hasSuffix("/sendMessage") }
      #expect(sent.count == 1)
      let body = try #require(sent.first?.body)
      let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      #expect(payload["reply_markup"] == nil)
      #expect(payload["text"] as? String == LearningAcceptanceHarness.answer)
    }
  }
}
