import ClawCore
import GRDB

extension ScheduledLearningStoreGRDB {
  static func reflectionAuthorizationIsCurrent(
    _ db: Database,
    authorization: ReflectionAuthorization
  ) throws -> Bool {
    guard let current = try prepareReflection(db, trigger: authorization.trigger) else {
      return false
    }
    return ReflectionAuthorization(preparation: current) == authorization
  }

  static func jobIsRepeatable(_ db: Database, jobId: Int64) throws -> Bool {
    let row = try Row.fetchOne(
      db,
      sql: "SELECT status, recurrence FROM scheduled_jobs WHERE id = ?",
      arguments: [jobId]
    )
    guard
      let row,
      row["recurrence"] as String? != nil,
      let status = ScheduledJobStatus(rawValue: row["status"])
    else {
      return false
    }
    return status == .active || status == .paused
  }
}
