import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ConferenceStoreTests {
  @Test func participantCanSubmitOnlyOncePerCaseWithoutOverwritingOriginalAnswer() throws {
    // given
    let fixture = try Fixture()
    let first = try fixture.insert(
      userID: 101,
      answer: "Keep accessibility state in the component."
    )

    // when
    let second = try fixture.store.insertSubmission(
      id: UUID(),
      prepared: PreparedConferenceSubmission(
        caseSnapshot: first.caseSnapshot,
        answer: "Another idea",
        executionPolicyID: "replacement-policy"
      ),
      origin: first.origin,
      now: fixture.now.addingTimeInterval(1)
    )

    // then
    guard case .existing(let existing) = second else {
      Issue.record("Expected duplicate lookup")
      return
    }
    #expect(existing.id == first.id)
    #expect(existing.answer == first.answer)
    #expect(existing.origin == first.origin)
    #expect(existing.executionPolicyID == fixture.executionPolicyID)
  }

  @Test func differentParticipantsHaveIndependentSubmissions() throws {
    // given
    let fixture = try Fixture()

    // when
    let first = try fixture.insert(userID: 101, answer: "Approach A")
    let second = try fixture.insert(userID: 202, answer: "Approach B")

    // then
    #expect(first.id != second.id)
    #expect(
      try fixture.store.submission(participantUserID: 101, caseID: "day-1")?.answer == "Approach A"
    )
    #expect(
      try fixture.store.submission(participantUserID: 202, caseID: "day-1")?.answer == "Approach B"
    )
  }

  @Test func queueClaimIsFIFOAndCannotClaimSameRowTwice() throws {
    // given
    let fixture = try Fixture()
    let first = try fixture.insert(
      userID: 101,
      answer: "First",
      id: #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
    )
    let second = try fixture.insert(
      userID: 202,
      answer: "Second",
      id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    )

    // when
    let claimedFirst = try fixture.store.claimNextQueued(now: fixture.now.addingTimeInterval(20))
    let claimedSecond = try fixture.store.claimNextQueued(now: fixture.now.addingTimeInterval(21))

    // then
    #expect(claimedFirst?.id == first.id)
    #expect(claimedFirst?.state == .running)
    #expect(claimedSecond?.id == second.id)
    #expect(try fixture.store.claimNextQueued(now: fixture.now.addingTimeInterval(22)) == nil)
  }

  @Test func requeueNeverReleasesSubmissionAfterCoderJobIsAttached() throws {
    // given — real message/run/approval references, with foreign keys enabled.
    let fixture = try Fixture()
    let submission = try fixture.insert(userID: 101, answer: "Answer")
    _ = try fixture.store.claimNextQueued(now: fixture.now)
    let jobID = try fixture.seedCoderJob(for: submission)
    _ = try fixture.store.attachCoderJob(
      submissionID: submission.id,
      coderJobID: jobID,
      now: fixture.now
    )

    // when
    let requeued = try fixture.store.requeue(submissionID: submission.id, now: fixture.now)

    // then
    #expect(requeued?.state == .running)
    #expect(requeued?.coderJobID == jobID)
  }

  @Test func terminalResultBecomesPendingNotificationUntilDurablyMarked() throws {
    // given
    let fixture = try Fixture()
    let submission = try fixture.insert(userID: 101, answer: "Answer")
    _ = try fixture.store.claimNextQueued(now: fixture.now)

    // when
    _ = try fixture.store.finish(
      submissionID: submission.id,
      state: .completed,
      pullRequestURL: "https://github.com/wowlocal/crew18-sim/pull/42",
      branch: "conference/example",
      commit: String(repeating: "a", count: 40),
      failureReason: nil,
      now: fixture.now
    )

    // then
    #expect(try fixture.store.pendingNotifications().map(\.id) == [submission.id])
    _ = try fixture.store.markNotificationEnqueued(submissionID: submission.id, now: fixture.now)
    #expect(try fixture.store.pendingNotifications().isEmpty)
  }
}

private extension ConferenceStoreTests {
  struct Fixture {
    let queue: DatabaseQueue
    let store: ConferenceStoreGRDB
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let executionPolicyID = "conference-test-policy"
    let item = ConferenceCase(
      id: "day-1",
      title: "Accessibility",
      prompt: "Propose a solution.",
      repositoryURL: "https://github.com/wowlocal/crew18-sim",
      baselineRef: String(repeating: "b", count: 40),
      baseBranch: "challenge/day-1"
    )

    init() throws {
      queue = try ClawDatabase.makeInMemoryQueue()
      try ClawDatabase.migrate(queue)
      store = ConferenceStoreGRDB(writer: queue)
    }

    func insert(
      userID: Int64,
      answer: String,
      id: UUID = UUID()
    ) throws -> ConferenceSubmission {
      let prepared = PreparedConferenceSubmission(
        caseSnapshot: item,
        answer: answer,
        executionPolicyID: executionPolicyID
      )
      let origin = try ConferenceApprovedOriginFixture.make(
        queue: queue,
        prepared: prepared,
        userID: userID,
        updateID: userID,
        now: now
      )
      let result = try store.insertSubmission(
        id: id,
        prepared: prepared,
        origin: origin,
        now: now
      )
      guard case .inserted(let submission) = result else {
        throw StoreError.unexpected("Expected fresh submission")
      }
      return submission
    }

    func seedCoderJob(for submission: ConferenceSubmission) throws -> UUID {
      let request = CoderRequest(
        source: .local(path: "/fixture/source"),
        task: "test",
        workspace: .separate,
        startRef: item.baselineRef,
        deliverable: .localChanges,
        baseBranch: nil,
        instructions: nil,
        publishExistingChanges: false
      )
      let prepared = CoderPreparedRequest(
        request: request,
        canonicalSource: "/fixture/source",
        checkoutPath: "/fixture/source",
        commonGitDirectory: "/fixture/source/.git",
        executionPolicyID: "conference-test-policy",
        publicationRepository: nil
      )
      let origin = submission.origin
      let admission = try CoderJobStoreGRDB(writer: queue).admit(
        id: UUID(),
        prepared: prepared,
        origin: CoderOrigin(
          runID: origin.runID,
          sessionID: origin.sessionID,
          requesterUserID: origin.requesterUserID,
          chatID: origin.chatID,
          toolCallID: origin.toolCallID,
          approvalID: origin.approvalID
        ),
        maxConcurrentJobs: 4,
        now: now
      )
      guard case .admitted(let job) = admission else {
        throw StoreError.unexpected("Expected Coder admission")
      }
      return job.id
    }
  }
}
