import ClawAgent
import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite struct LearningLoopAcceptanceTests {
  @Test func oneOwnerCorrectionPromotesThroughTheAssembledDaemon() async throws {
    try await LearningAcceptanceHarness.withHarness(learningEnabled: true) { env in
      // given
      let first = try await env.fireScheduledRun()
      let service = try #require(env.learning)
      let base = try #require(try env.stores.learning.binding(runId: first)).stableDigest
      #expect(try env.stores.learning.evaluation(runId: first) != nil)

      // when
      try await env.correct(runId: first)
      let trial = try #require(try env.stores.learning.openTrial(jobId: env.jobId))
      let firstTrial = try await env.runNow()
      let secondTrial = try await env.runNow()

      // then
      let state = try #require(try env.stores.learning.learningState(jobId: env.jobId))
      #expect(state.stableDigest != base)
      #expect(try env.stores.learning.binding(runId: firstTrial)?.trialId == trial.trialId)
      #expect(try env.stores.learning.binding(runId: secondTrial)?.trialId == trial.trialId)
      #expect(try env.stores.learning.currentPromotion(jobId: env.jobId) != nil)
      await service.waitForPendingWork()

      // when
      try await env.withRestarted { restarted in
        let next = try await restarted.runNow()

        // then
        #expect(
          try restarted.stores.learning.binding(runId: next)?.effectiveDigest == state.stableDigest
        )
        let requests = await restarted.llm.recorded
        let body = try #require(requests.first?.body)
        let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(request["messages"] as? [[String: Any]])
        let message = try #require(
          messages.first { message in
            (message["content"] as? String)?.contains(LearningAcceptanceHarness.lesson) == true
          }
        )
        let text = try #require(message["content"] as? String)
        #expect(message["role"] as? String == MessageRole.user.rawValue)
        #expect(text.contains(ContextBuilder.lessonsLabel))
        let fence = LabeledContext(label: ContextBuilder.lessonsLabel, content: "", nonce: "")
          .render()
        let opening = try #require(fence.split(separator: " ").first)
        #expect(text.hasPrefix(String(opening)))

        // when — a crash between fire and lane pickup, after the owner resets the active pointer
        guard
          case .fired(let pending) = try restarted.stores.scheduledJobs.fireNow(
            jobId: env.jobId,
            now: LearningAcceptanceHarness.now
          )
        else {
          Issue.record("expected a real pending fire")
          await restarted.stop()
          return
        }
        let pinned = try #require(try restarted.stores.learning.binding(runId: pending.runId))
        let bytes = try #require(
          try restarted.stores.learning.lessonSet(
            jobId: env.jobId,
            digest: pinned.effectiveDigest
          )
        ).canonicalBytes
        try await restarted.submit(message: "/learning reset \(env.jobId)")
        try await restarted.submit(message: "yes")
        let reset = try #require(try restarted.stores.learning.learningState(jobId: env.jobId))
        #expect(reset.stableDigest != pinned.effectiveDigest)
        try await restarted.withRestarted { afterCrash async throws in
          // then — boot fails the orphan; it neither resumes it nor rebinds it to the new stable set
          #expect(try afterCrash.runState(pending.runId) == .failed)
          #expect(try afterCrash.stores.learning.binding(runId: pending.runId) == pinned)
          #expect(
            try afterCrash.stores.learning.lessonSet(
              jobId: env.jobId,
              digest: pinned.effectiveDigest
            )?.canonicalBytes == bytes
          )
        }
      }
    }
  }

  @Test func aNegativeTrialRunFallsBackThroughSettlementNotification() async throws {
    try await LearningAcceptanceHarness.withHarness(learningEnabled: true, negativeTrial: true) {
      env in
      // given
      let first = try await env.fireScheduledRun()
      let base = try #require(try env.stores.learning.binding(runId: first)).stableDigest
      try await env.correct(runId: first)
      let trial = try #require(try env.stores.learning.openTrial(jobId: env.jobId))

      // when
      let negative = try await env.runNow()

      // then
      #expect(try env.stores.learning.binding(runId: negative)?.trialId == trial.trialId)
      #expect(try env.stores.learning.openTrial(jobId: env.jobId) == nil)
      #expect(try env.stores.learning.learningState(jobId: env.jobId)?.stableDigest == base)
      #expect(try env.stores.learning.currentPromotion(jobId: env.jobId) == nil)
    }
  }
}
