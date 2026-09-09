import Foundation

public enum ConferenceSubmissionInsert: Sendable, Equatable {
  case inserted(ConferenceSubmission)
  case existing(ConferenceSubmission)
}

/// Persistence seam for the conference workflow. Every state transition is a compare-and-set so a
/// restart or a second service loop cannot duplicate a coding run.
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

  /// Atomically claims the oldest queued submission. Nil means the queue is empty.
  func claimNextQueued(now: Date) throws(StoreError) -> ConferenceSubmission?

  /// Attaches the single admitted Coder job to the claimed submission.
  func attachCoderJob(
    submissionID: UUID,
    coderJobID: UUID,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission?

  /// A busy/unavailable Coder releases a claim back to the durable FIFO without changing the answer.
  func requeue(submissionID: UUID, now: Date) throws(StoreError) -> ConferenceSubmission?

  func runningSubmissions() throws(StoreError) -> [ConferenceSubmission]

  /// Commits a terminal projection of the linked Coder result. Replaying the same terminal result is
  /// idempotent; a different terminal state after completion is refused by returning the stored row.
  func finish(
    submissionID: UUID,
    state: ConferenceSubmissionState,
    pullRequestURL: String?,
    branch: String?,
    commit: String?,
    failureReason: String?,
    now: Date
  ) throws(StoreError) -> ConferenceSubmission?
}

/// Keeps existing composition/test fixtures source-compatible when conference mode is absent.
/// Production always wires the GRDB store after the conference migration has run.
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
}
