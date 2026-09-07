import ClawCore
import Foundation

extension CoderService {
  func reconcile() async throws {
    do {
      for job in try store.reservedJobs() {
        try await reconcileOwnership(job)
        if job.state.isTerminal {
          guard let current = try store.job(id: job.id) else {
            throw StoreError.unexpected("Coder recovery lost a reserved job")
          }
          if current.ownership == .none || current.ownership == .stopped {
            try store.releaseResolvedReservation(id: job.id, now: Date())
          }
        } else {
          try await complete(
            id: job.id,
            result: Self.unfinishedResult(state: .interrupted),
            recovering: true
          )
        }
      }
    } catch let error as StoreError {
      fail(.persistence(error))
      throw error
    }
  }
}

// MARK: - Read-only Ownership Reconciliation

private extension CoderService {
  func reconcileOwnership(_ job: CoderJob) async throws {
    if job.ownership == .none || job.ownership == .stopped { return }
    guard let receipt = job.processReceipt else {
      throw StoreError.unexpected("Coder active ownership has no pending launch receipt")
    }
    let observation = await inspector.inspect(receipt)
    switch observation {
    case .stopped:
      try store.recordProcess(id: job.id, event: .stopped(launchID: receipt.launchID), now: Date())
      recoveryRequiredJobIDs.remove(job.id)
    case .liveOwned, .unresolved:
      try store.recordProcess(
        id: job.id,
        event: .unresolved(launchID: receipt.launchID),
        now: Date()
      )
      recoveryRequiredJobIDs.insert(job.id)
    }
  }
}
