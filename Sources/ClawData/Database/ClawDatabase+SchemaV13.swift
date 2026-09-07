import ClawCore
import GRDB

// MARK: - Schema V13

extension ClawDatabase {
  static func replaceOpenTrialIndexWithLiveTrialIndex(_ db: Database) throws {
    try db.drop(index: "idx_learning_trials_open_job")
    let open = LearningTrialState.open.rawValue
    let draining = LearningTrialState.draining.rawValue
    try db.execute(
      sql: """
        CREATE UNIQUE INDEX idx_learning_trials_live_job ON learning_trials(job_id)
        WHERE state IN ('\(open)', '\(draining)')
        """
    )
  }
}
