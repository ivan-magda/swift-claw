import ClawAgent
import ClawCore
import Foundation

// MARK: - Context Assembly

extension TurnRunner {
  /// Everything `runTurn` needs from the stores at turn start, loaded together so `run` and
  /// `resume` share one assembly path.
  struct TurnInputs {
    let snapshot: SessionContextSnapshot
    let buildResult: BuildResult
    let todayTokens: Int
    let todayUSD: Double
    let proactiveTodayUSD: Double
  }

  /// Loads the bounded snapshot, today's budget totals, and the assembled context in one place —
  /// `run` and `resume` share it; only the bounding message id and the clock differ.
  func loadTurnInputs(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    sessionId: Int64,
    boundMessageId: Int64,
    origin: RunOrigin,
    at clock: Date,
    images: [Int64: ImagePart]
  ) throws -> TurnInputs {
    let loaded = try sessionMessages.loadContextSnapshot(
      sessionId: sessionId,
      throughMessageId: boundMessageId,
      limit: Self.historyLimit
    )
    let snapshot = Self.attach(images, to: loaded)
    let totals = try usageStore.todayTokensAndCost(now: clock)
    // The proactive pool is one aggregate over scheduled + heartbeat; interactive runs never
    // pay for the extra query.
    let proactiveTodayUSD: Double
    if origin == .interactive {
      proactiveTodayUSD = 0
    } else {
      proactiveTodayUSD =
        try usageStore.todayTokensAndCost(
          origins: RunOrigin.proactiveOrigins,
          now: clock
        ).costUSD
    }
    // Before assembly, and before any provider call: a bound run whose pinned set cannot be
    // resolved must fail rather than answer against a set its binding never froze.
    let lessons = try pinnedLessons(runId: runId)
    let buildResult = try contextBuilder.assemble(
      snapshot: snapshot,
      sessionId: sessionId,
      origin: origin,
      lessons: lessons
    )
    return TurnInputs(
      snapshot: snapshot,
      buildResult: buildResult,
      todayTokens: totals.tokens,
      todayUSD: totals.costUSD,
      proactiveTodayUSD: proactiveTodayUSD
    )
  }
}

// MARK: - Pinned Context

private extension TurnRunner {
  /// Most-recent messages pulled for context; `ContextBuilder` then caps by grapheme budget.
  static let historyLimit = 50

  /// The lesson set this run's fire froze, or nil when it carries no binding. Every identity is
  /// re-checked here rather than trusted from the read: `(job_id, digest)` is what names a lesson
  /// set, so two jobs holding the same rules share a digest and a digest-only match would silently
  /// run one job's evidence against another's lessons.
  func pinnedLessons(runId: Int64) throws -> LessonSet? {
    guard let learning, let binding = try learning.binding(runId: runId) else {
      return nil
    }
    guard try runs.jobId(runId: runId) == binding.jobId else {
      throw PinnedLessonFailure.identityMismatch(runId: runId)
    }
    guard
      let set = try learning.lessonSet(jobId: binding.jobId, digest: binding.effectiveDigest)
    else {
      throw PinnedLessonFailure.missingSet(runId: runId, digest: binding.effectiveDigest)
    }
    guard set.jobId == binding.jobId, set.digest == binding.effectiveDigest else {
      throw PinnedLessonFailure.identityMismatch(runId: runId)
    }
    return set
  }
}
