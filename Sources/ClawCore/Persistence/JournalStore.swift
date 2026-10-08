import Foundation

public protocol JournalStore: Sendable {
  func pendingSources(ownerUserID: Int64, now: Date) throws(StoreError) -> [JournalSource]

  func startBatch(
    _ request: JournalStartRequest,
    now: Date
  ) throws(StoreError) -> JournalStartOutcome

  func finishBatch(
    id: UUID,
    outcome: JournalOutcome,
    usage: ProviderUsage?,
    now: Date
  ) throws(StoreError)

  func canPublish(batchID: UUID) throws(StoreError) -> Bool

  func pendingCount(day: JournalDay, ownerUserID: Int64) throws(StoreError) -> Int

  func cancelDay(_ day: JournalDay, ownerUserID: Int64, now: Date) throws(StoreError) -> Int

  func skipSources(ids: [String], reason: String, now: Date) throws(StoreError)

  func reconcileAtBoot(now: Date) throws(StoreError)

  func status(ownerUserID: Int64, now: Date) throws(StoreError) -> JournalStatus
}
