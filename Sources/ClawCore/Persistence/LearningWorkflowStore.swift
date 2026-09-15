import Foundation

public struct LearningCandidateControl: Sendable {
  public let eventID: Int64
  public let candidate: CandidateDigest
  public let signal: OwnerSignal
  public let payload: String?

  public init(eventID: Int64, candidate: CandidateDigest, signal: OwnerSignal, payload: String?) {
    self.eventID = eventID
    self.candidate = candidate
    self.signal = signal
    self.payload = payload
  }
}

/// Recovery reads never arm jobs. Transition ownership stays in the existing write transactions.
public protocol LearningWorkflowStore: ScheduledLearningStore {
  func workflowJobs(after jobID: Int64, limit: Int) throws(StoreError) -> [Int64]

  func workflowRuns(jobID: Int64, after runID: Int64, limit: Int) throws(StoreError) -> [Int64]

  func learningState(jobID: Int64) throws(StoreError) -> JobLearningState?

  func workflowTriggers(jobID: Int64, now: Date) throws(StoreError) -> [TriggerIdentity]

  func workflowCandidates(jobID: Int64) throws(StoreError) -> [CandidateDigest]

  func workflowControls(jobID: Int64) throws(StoreError) -> [LearningCandidateControl]

  func workflowRollbacks(jobID: Int64) throws(StoreError) -> [RollbackTrigger]
}
