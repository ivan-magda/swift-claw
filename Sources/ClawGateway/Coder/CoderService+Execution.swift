import ClawCore
import Foundation

extension CoderService {
  func execute(_ admitted: CoderJob, backend: any CoderBackend) async {
    defer { tasks[admitted.id] = nil }
    do {
      let result: CoderResult
      if try store.markRunning(id: admitted.id, now: Date()) {
        let invocation = CoderInvocation(
          jobID: admitted.id,
          prepared: admitted.prepared,
          jobDirectory: URL(fileURLWithPath: jobRoot)
            .appendingPathComponent(admitted.id.uuidString).path,
          timeout: .seconds(config.jobTimeoutSeconds)
        )
        result = await backend.run(invocation) { event in
          try await self.recordProcess(id: admitted.id, event: event)
        }
      } else {
        result = Self.unfinishedResult(state: .cancelled)
      }
      if case .persistence = failure { return }
      try await complete(id: admitted.id, result: result, recovering: false)
    } catch let error as StoreError {
      fail(.persistence(error))
    } catch {
      fail(.persistence(.unexpected("Coder completion failed: \(error)")))
    }
  }

  func complete(id: UUID, result: CoderResult, recovering: Bool) async throws {
    guard var job = try store.job(id: id) else {
      throw StoreError.unexpected("Coder completion has no job")
    }
    while !job.state.isTerminal {
      let selected = Self.selectedResult(result, persistedState: job.state)
      let chunks = report.chunks(job: job, result: selected)
      let resolved = job.ownership == .none || job.ownership == .stopped
      let outcome = try store.complete(
        id: id,
        expectedState: job.state,
        result: selected,
        chunks: chunks,
        releaseReservation: resolved,
        now: Date()
      )
      switch outcome {
      case .stateChanged(let current): job = current
      case .alreadyTerminal: return
      case .committed:
        if !resolved {
          recoveryRequiredJobIDs.insert(id)
          if !recovering { fail(.cleanup(jobID: id)) }
        }
        await notifyOutbox()
        return
      }
    }
  }

  static func unfinishedResult(state: CoderJobState) -> CoderResult {
    let interrupted = state == .interrupted
    return CoderResult(
      state: state,
      summary: interrupted
        ? "Daemon interrupted this task. It was not rerun; inspect its workspace and publication."
        : "Cancellation stopped this task before completion.",
      workspacePath: nil,
      startingCommit: nil,
      baselineObserved: false,
      changedFiles: nil,
      branch: nil,
      commit: nil,
      publication: .unknown(reportedURL: nil),
      reportedChecks: [],
      reportedUsage: nil,
      commitAuthor: nil,
      githubActor: nil,
      failure: interrupted
        ? CoderFailure(
          stage: .interrupted,
          message: "Daemon stopped before a terminal result committed."
        )
        : nil
    )
  }
}

// MARK: - Process Events and Stop Precedence

private extension CoderService {
  func recordProcess(id: UUID, event: CoderProcessEvent) throws {
    do {
      if case .willLaunch = event, try store.job(id: id)?.state == .stopping {
        throw CancellationError()
      }
      try store.recordProcess(id: id, event: event, now: Date())
    } catch let error as StoreError {
      fail(.persistence(error))
      throw error
    }
  }

  static func selectedResult(_ result: CoderResult, persistedState: CoderJobState) -> CoderResult {
    guard persistedState == .stopping,
      result.state != .cancelled, result.state != .timedOut, result.state != .interrupted
    else {
      return result
    }
    return CoderResult(
      state: .cancelled,
      summary: "Cancellation was requested before task completion committed.",
      workspacePath: result.workspacePath,
      startingCommit: result.startingCommit,
      baselineObserved: result.baselineObserved,
      changedFiles: result.changedFiles,
      branch: result.branch,
      commit: result.commit,
      publication: result.publication,
      reportedChecks: result.reportedChecks,
      reportedUsage: result.reportedUsage,
      commitAuthor: result.commitAuthor,
      githubActor: result.githubActor,
      failure: result.failure
    )
  }
}
