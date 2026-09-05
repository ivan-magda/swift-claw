import Foundation

public struct LearningCandidateControl: Sendable {
  public let eventId: Int64
  public let candidate: CandidateDigest
  public let signal: OwnerSignal
  public let payload: String?

  public init(eventId: Int64, candidate: CandidateDigest, signal: OwnerSignal, payload: String?) {
    self.eventId = eventId
    self.candidate = candidate
    self.signal = signal
    self.payload = payload
  }
}

/// Recovery reads never arm jobs. Transition ownership stays in the existing write transactions.
public protocol LearningWorkflowStore: ScheduledLearningStore {
  func workflowJobs(after jobId: Int64, limit: Int) throws(StoreError) -> [Int64]
  func workflowRuns(jobId: Int64, after runId: Int64, limit: Int) throws(StoreError) -> [Int64]
  func learningState(jobId: Int64) throws(StoreError) -> JobLearningState?
  func workflowTriggers(jobId: Int64, now: Date) throws(StoreError) -> [TriggerIdentity]
  func workflowCandidates(jobId: Int64) throws(StoreError) -> [CandidateDigest]
  func workflowControls(jobId: Int64) throws(StoreError) -> [LearningCandidateControl]
  func workflowRollbacks(jobId: Int64) throws(StoreError) -> [RollbackTrigger]
}
