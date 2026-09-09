import Foundation

public enum ConferenceSubmissionInsert: Sendable, Equatable {
  case inserted(ConferenceSubmission)
  case existing(ConferenceSubmission)
}

public protocol ConferenceStore: Sendable {
  func insertSubmission(
    id: UUID,
    prepared: PreparedConferenceSubmission,
    origin: ConferenceApprovedOrigin,
    now: Date
  ) throws(StoreError) -> ConferenceSubmissionInsert

  func submission(id: UUID) throws(StoreError) -> ConferenceSubmission?

  func submission(participantUserID: Int64, caseID: String) throws(StoreError)
    -> ConferenceSubmission?

  func claimNextQueued(now: Date) throws(StoreError) -> ConferenceSubmission?

  func attachCoderJob(
    submissionID: UUID,
    coderJobID: UUID,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission?

  func requeue(submissionID: UUID, now: Date) throws(StoreError) -> ConferenceSubmission?

  func runningSubmissions() throws(StoreError) -> [ConferenceSubmission]

  func finish(
    submissionID: UUID,
    state: ConferenceSubmissionState,
    pullRequestURL: String?,
    branch: String?,
    commit: String?,
    failureReason: String?,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission?

  /// Terminal rows remain here until their idempotent outbox notice is durably claimed.
  func pendingNotifications() throws(StoreError) -> [ConferenceSubmission]

  func markNotificationEnqueued(
    submissionID: UUID,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission?
}

public struct DisabledConferenceStore: ConferenceStore {
  public init() {}

  public func insertSubmission(
    id: UUID,
    prepared: PreparedConferenceSubmission,
    origin: ConferenceApprovedOrigin,
    now: Date
  ) throws(StoreError) -> ConferenceSubmissionInsert {
    throw StoreError.unexpected("Conference workflow is not configured")
  }

  public func submission(id: UUID) throws(StoreError) -> ConferenceSubmission? { nil }

  public func submission(
    participantUserID: Int64,
    caseID: String
  ) throws(StoreError) -> ConferenceSubmission? { nil }

  public func claimNextQueued(now: Date) throws(StoreError) -> ConferenceSubmission? { nil }

  public func attachCoderJob(
    submissionID: UUID,
    coderJobID: UUID,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission? { nil }

  public func requeue(
    submissionID: UUID,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission? { nil }

  public func runningSubmissions() throws(StoreError) -> [ConferenceSubmission] { [] }

  public func finish(
    submissionID: UUID,
    state: ConferenceSubmissionState,
    pullRequestURL: String?,
    branch: String?,
    commit: String?,
    failureReason: String?,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission? { nil }

  public func pendingNotifications() throws(StoreError) -> [ConferenceSubmission] { [] }

  public func markNotificationEnqueued(
    submissionID: UUID,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission? { nil }
}
