import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct LessonSetStoreTests {
  @Test func twoJobsHoldTheSameEmptySetIndependently() throws {
    // given
    let queue = try Self.makeArmedDatabase(jobIds: [1, 2])
    let store = ScheduledLearningStoreGRDB(writer: queue)
    let now = Date()

    // when
    let first = try store.armJob(jobId: 1, now: now)
    let second = try store.armJob(jobId: 2, now: now)

    // then
    #expect(first.stableDigest == second.stableDigest)
    let firstSet = try #require(try store.lessonSet(jobId: 1, digest: first.stableDigest))
    let secondSet = try #require(try store.lessonSet(jobId: 2, digest: second.stableDigest))
    #expect(firstSet.jobId == 1)
    #expect(secondSet.jobId == 2)
  }

  @Test func armingIsIdempotent() throws {
    // given
    let queue = try Self.makeArmedDatabase(jobIds: [1])
    let store = ScheduledLearningStoreGRDB(writer: queue)

    // when
    let first = try store.armJob(jobId: 1, now: Date())
    let second = try store.armJob(jobId: 1, now: Date())

    // then
    #expect(first == second)
  }

  @Test func aLessonSetIsInvisibleToAnotherJob() throws {
    // given
    let queue = try Self.makeArmedDatabase(jobIds: [1, 2])
    let store = ScheduledLearningStoreGRDB(writer: queue)
    let state = try store.armJob(jobId: 1, now: Date())

    // when
    let crossJob = try store.lessonSet(jobId: 2, digest: state.stableDigest)

    // then
    #expect(crossJob == nil)
  }

  @Test func armingAnEmptySetStoresItsCanonicalContent() throws {
    // given
    let queue = try Self.makeArmedDatabase(jobIds: [1])
    let store = ScheduledLearningStoreGRDB(writer: queue)

    // when
    let state = try store.armJob(jobId: 1, now: Date())
    let set = try #require(try store.lessonSet(jobId: 1, digest: state.stableDigest))

    // then
    #expect(set == LessonSet.empty(jobId: 1))
    #expect(state.epoch == LearningEpoch(1))
    #expect(state.stableRevision == StableRevision(0))
    #expect(state.feedbackRevision == FeedbackRevision(0))
    #expect(state.openTrialId == nil)
  }
}

// MARK: - Fixtures

private extension LessonSetStoreTests {
  /// `job_learning_state.job_id` is a foreign key, so a job row has to exist before it can arm.
  static func makeArmedDatabase(jobIds: [Int64]) throws -> DatabaseQueue {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try queue.write { db in
      for jobId in jobIds {
        try db.execute(
          sql: """
            INSERT INTO scheduled_jobs(id, owner_chat_id, label, prompt, timezone, status,
              created_ts, updated_ts)
            VALUES (?, 777, 'digest', 'Summarize my unread items', 'Europe/Berlin', 'active', 0, 0)
            """,
          arguments: [jobId]
        )
      }
    }
    return queue
  }
}
