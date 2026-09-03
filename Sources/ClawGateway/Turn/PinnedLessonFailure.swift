import ClawCore
import Foundation

/// Why a bound run could not be answered against the lesson set its fire froze. Both cases fail the
/// run through the pre-dispatch tail: the accepted algorithm forbids substituting the job's current,
/// empty or shortened set, because that would evaluate a hypothesis the binding never froze.
enum PinnedLessonFailure: Error, Equatable {
  /// The binding names a set this job does not hold — the run's frozen lessons are unreadable.
  case missingSet(runId: Int64, digest: LessonSetDigest)
  /// The run, its binding and the resolved set do not all name the same job. A lesson set is
  /// identified by `(job_id, digest)`, so a digest match alone can span two jobs.
  case identityMismatch(runId: Int64)
}
