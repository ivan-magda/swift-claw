import ClawCore
import Foundation
import Testing

@testable import ClawData

@Suite
struct LessonSetStoreTests {
  @Test
  func twoJobsHoldTheSameEmptySetIndependently() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let other = try makeOtherJob(in: env)

    // when
    let firstRunID = try env.pendingBoundRun()
    let secondOutcome = try env.jobs.fireNow(jobID: other.id, now: env.now)

    // then
    guard case .fired(let second) = secondOutcome else {
      Issue.record("expected the other job to fire")
      return
    }
    let first = try #require(try env.learning.binding(runID: firstRunID))
    let secondBinding = try #require(second.binding)
    #expect(first.stableDigest == secondBinding.stableDigest)
    #expect(
      try env.learning.lessonSet(jobID: env.jobID, digest: first.stableDigest)
        == LessonSet.empty(jobID: env.jobID)
    )
    #expect(
      try env.learning.lessonSet(jobID: other.id, digest: secondBinding.stableDigest)
        == LessonSet.empty(jobID: other.id)
    )
  }

  @Test
  func aLessonSetIsInvisibleToAnotherJob() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let other = try makeOtherJob(in: env)
    let runID = try env.pendingBoundRun()
    let binding = try #require(try env.learning.binding(runID: runID))

    // when
    let crossJob = try env.learning.lessonSet(jobID: other.id, digest: binding.stableDigest)

    // then
    #expect(crossJob == nil)
  }
}

// MARK: - Fixtures

private extension LessonSetStoreTests {
  func makeOtherJob(in env: BoundRunEnvironment) throws -> ScheduledJob {
    try env.jobs.create(
      NewScheduledJob(
        ownerChatID: 777,
        label: "other digest",
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: env.now
      ),
      now: env.now
    )
  }
}
