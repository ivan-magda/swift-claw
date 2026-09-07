import Foundation

public enum CoderAdmission: Sendable, Equatable {
  case admitted(CoderJob)
  case existing(CoderJob)
  case busy, workspaceBusy, recoveryRequired
}
public enum CoderCompletionOutcome: Sendable, Equatable {
  case committed, alreadyTerminal
  case stateChanged(CoderJob)
}
public protocol CoderJobStore: Sendable {
  func admit(
    id: UUID,
    prepared: CoderPreparedRequest,
    origin: CoderOrigin,
    maxConcurrentJobs: Int,
    now: Date
  ) throws(StoreError) -> CoderAdmission
  func job(id: UUID) throws(StoreError) -> CoderJob?
  /// The latest updated failed, timed-out or interrupted job, including released reservations.
  func lastFailedJob() throws(StoreError) -> CoderJob?
  func reservedJobs() throws(StoreError) -> [CoderJob]
  func markRunning(id: UUID, now: Date) throws(StoreError) -> Bool
  func requestCancellation(id: UUID, now: Date) throws(StoreError) -> CoderJob?
  func recordProcess(id: UUID, event: CoderProcessEvent, now: Date) throws(StoreError)
  /// Commits the terminal result and notice only if the rendered state still matches.
  /// Releasing the slot additionally requires resolved process ownership.
  func complete(  // swiftlint:disable:this function_parameter_count
    id: UUID,
    expectedState: CoderJobState,
    result: CoderResult,
    chunks: [OutboxChunk],
    releaseReservation: Bool,
    now: Date
  ) throws(StoreError) -> CoderCompletionOutcome
  func releaseResolvedReservation(id: UUID, now: Date) throws(StoreError)
}
