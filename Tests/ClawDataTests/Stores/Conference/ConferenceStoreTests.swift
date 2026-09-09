import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ConferenceStoreTests {
  @Test func participantCanSubmitOnlyOncePerCaseWithoutOverwritingOriginalAnswer() throws {
    let fixture = try Fixture()
    let first = try fixture.store.insertSubmission(
      id: UUID(),
      prepared: fixture.prepared(answer: "Keep the accessibility state in the component."),
      origin: fixture.origin(userID: 101),
      now: fixture.now
    )
    let second = try fixture.store.insertSubmission(
      id: UUID(),
      prepared: fixture.prepared(answer: "Replace it with a completely different idea."),
      origin: fixture.origin(userID: 101, toolCallID: "second"),
      now: fixture.now.addingTimeInterval(1)
    )

    guard case .inserted(let inserted) = first, case .existing(let existing) = second else {
      Issue.record("Expected first insert and duplicate lookup")
      return
    }
    #expect(existing.id == inserted.id)
    #expect(existing.answer == "Keep the accessibility state in the component.")
    #expect(existing.origin.toolCallID == "tool-101")
  }

  @Test func differentParticipantsHaveIndependentSubmissions() throws {
    let fixture = try Fixture()
    let first = try fixture.insert(userID: 101, answer: "Approach A")
    let second = try fixture.insert(userID: 202, answer: "Approach B")

    #expect(first.id != second.id)
    #expect(first.answer == "Approach A")
    #expect(second.answer == "Approach B")
    #expect(
      try fixture.store.submission(participantUserID: 101, caseID: fixture.caseItem.id)?.id
        == first.id
    )
    #expect(
      try fixture.store.submission(participantUserID: 202, caseID: fixture.caseItem.id)?.id
        == second.id
    )
  }

  @Test func queueClaimIsFIFOAndCannotClaimSameRowTwice() throws {
    let fixture = try Fixture()
    let first = try fixture.insert(userID: 101, answer: "First", at: fixture.now)
    let second = try fixture.insert(
      userID: 202,
      answer: "Second",
      at: fixture.now.addingTimeInterval(10)
    )

    let claimedFirst = try fixture.store.claimNextQueued(now: fixture.now.addingTimeInterval(20))
    let claimedSecond = try fixture.store.claimNextQueued(now: fixture.now.addingTimeInterval(21))
    let empty = try fixture.store.claimNextQueued(now: fixture.now.addingTimeInterval(22))

    #expect(claimedFirst?.id == first.id)
    #expect(claimedFirst?.state == .running)
    #expect(claimedSecond?.id == second.id)
    #expect(claimedSecond?.state == .running)
    #expect(empty == nil)
  }

  @Test func requeueNeverReleasesSubmissionAfterCoderJobIsAttached() throws {
    let fixture = try Fixture()
    let submission = try fixture.insert(userID: 101, answer: "Answer")
    _ = try fixture.store.claimNextQueued(now: fixture.now.addingTimeInterval(1))

    let coderJobID = try fixture.seedCoderJob(for: submission)
    let attached = try fixture.store.attachCoderJob(
      submissionID: submission.id,
      coderJobID: coderJobID,
      now: fixture.now.addingTimeInterval(2)
    )
    let afterRequeue = try fixture.store.requeue(
      submissionID: submission.id,
      now: fixture.now.addingTimeInterval(3)
    )

    #expect(attached?.coderJobID == coderJobID)
    #expect(afterRequeue?.state == .running)
    #expect(afterRequeue?.coderJobID == coderJobID)
  }

  @Test func terminalResultBecomesPendingNotificationUntilDurablyMarked() throws {
    let fixture = try Fixture()
    let submission = try fixture.insert(userID: 101, answer: "Answer")
    _ = try fixture.store.claimNextQueued(now: fixture.now.addingTimeInterval(1))

    let finished = try fixture.store.finish(
      submissionID: submission.id,
      state: .completed,
      pullRequestURL: "https://github.com/wowlocal/crew18-sim/pull/42",
      branch: "coder/example",
      commit: String(repeating: "a", count: 40),
      failureReason: nil,
      now: fixture.now.addingTimeInterval(2)
    )

    #expect(finished?.state == .completed)
    #expect(finished?.notificationEnqueued == false)
    #expect(try fixture.store.pendingNotifications().map(\.id) == [submission.id])

    let marked = try fixture.store.markNotificationEnqueued(
      submissionID: submission.id,
      now: fixture.now.addingTimeInterval(3)
    )
    #expect(marked?.notificationEnqueued == true)
    #expect(try fixture.store.pendingNotifications().isEmpty)
  }
}

private extension ConferenceStoreTests {
  struct Fixture {
    let queue: DatabaseQueue
    let store: ConferenceStoreGRDB
    let coderJobs: CoderJobStoreGRDB
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let caseItem = ConferenceCase(
      id: "day-1",
      title: "Accessibility regression",
      prompt: "A design-system release introduced accessibility regressions. Propose a solution.",
      repositoryURL: "https://github.com/wowlocal/crew18-sim",
      baselineRef: String(repeating: "b", count: 40),
      baseBranch: "challenge/day-1"
    )

    init() throws {
      queue = try ClawDatabase.makeInMemoryQueue()
      try ClawDatabase.migrate(queue)
      store = ConferenceStoreGRDB(writer: queue)
      coderJobs = CoderJobStoreGRDB(writer: queue)
    }

    func prepared(answer: String) -> PreparedConferenceSubmission {
      PreparedConferenceSubmission(caseSnapshot: caseItem, answer: answer)
    }

    func origin(
      userID: Int64,
      toolCallID: String? = nil
    ) -> ConferenceApprovedOrigin {
      ConferenceApprovedOrigin(
        runID: userID,
        sessionID: userID,
        chatID: userID,
        requesterUserID: userID,
        mode: .direct,
        toolCallID: toolCallID ?? "tool-\(userID)",
        approvalID: userID
      )
    }

    func insert(
      userID: Int64,
      answer: String,
      at: Date? = nil
    ) throws -> ConferenceSubmission {
      let result = try store.insertSubmission(
        id: UUID(),
        prepared: prepared(answer: answer),
        origin: origin(userID: userID),
        now: at ?? now
      )
      guard case .inserted(let item) = result else {
        throw StoreError.unexpected("Fixture expected a fresh submission")
      }
      return item
    }

    func seedCoderJob(for submission: ConferenceSubmission) throws -> UUID {
      let request = CoderRequest(
        source: .githubRepository(url: caseItem.repositoryURL),
        task: "test",
        workspace: .separate,
        startRef: caseItem.baselineRef,
        deliverable: .pullRequest,
        baseBranch: caseItem.baseBranch,
        instructions: nil,
        publishExistingChanges: false
      )
      let prepared = CoderPreparedRequest(
        request: request,
        canonicalSource: caseItem.repositoryURL,
        checkoutPath: nil,
        commonGitDirectory: nil,
        executionPolicyID: "policy",
        publicationRepository: "wowlocal/crew18-sim"
      )
      let admission = try coderJobs.admit(
        id: UUID(),
        prepared: prepared,
        origin: CoderOrigin(
          runID: submission.origin.runID,
          sessionID: submission.origin.sessionID,
          requesterUserID: submission.participantUserID,
          chatID: submission.origin.chatID,
          toolCallID: submission.origin.toolCallID,
          approvalID: submission.origin.approvalID
        ),
        maxConcurrentJobs: 4,
        now: now
      )
      guard case .admitted(let job) = admission else {
        throw StoreError.unexpected("Fixture could not admit Coder job")
      }
      return job.id
    }
  }
}
