import ClawCore
import Foundation
import ServiceLifecycle

public enum CoderServiceFailure: Error, Sendable, Equatable {
  case persistence(StoreError)
  case cleanup(jobID: UUID)
}

public actor CoderService: CoderServing, Service {
  enum Lifecycle { case created, starting, accepting, stopping, stopped }

  let store: any CoderJobStore
  let backend: (any CoderBackend)?
  let preparer: any CoderRequestPreparing
  let inspector: any CoderProcessInspecting
  let config: CoderConfig
  let jobRoot: String
  let executionPolicyID: String
  let report: CoderCompletionReport
  let completionNoticesEnabled: Bool
  let notifyOutbox: @Sendable () async -> Void
  let failures: AsyncStream<Void>
  let failureSignal: AsyncStream<Void>.Continuation
  var lifecycle: Lifecycle = .created
  var startup: Task<Void, any Error>?
  var tasks: [UUID: Task<Void, Never>] = [:]
  public private(set) var failure: CoderServiceFailure?
  public internal(set) var recoveryRequiredJobIDs: Set<UUID> = []

  public init(
    store: any CoderJobStore,
    backend: (any CoderBackend)?,
    preparer: any CoderRequestPreparing,
    inspector: any CoderProcessInspecting,
    config: CoderConfig,
    jobRoot: String,
    executionPolicyID: String,
    completionNoticesEnabled: Bool = true,
    redact: @escaping @Sendable (String) -> String,
    notifyOutbox: @escaping @Sendable () async -> Void
  ) {
    self.store = store
    self.backend = backend
    self.preparer = preparer
    self.inspector = inspector
    self.config = config
    self.jobRoot = jobRoot
    self.executionPolicyID = executionPolicyID
    self.completionNoticesEnabled = completionNoticesEnabled
    report = CoderCompletionReport(redact: redact)
    self.notifyOutbox = notifyOutbox
    (failures, failureSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// Reconciles old reservations once, before approval replay or new submission can admit work.
  public func start() async throws {
    if let failure {
      throw failure
    }
    switch lifecycle {
    case .accepting: return
    case .stopping, .stopped: throw CoderError.unavailable("Coder is stopping.")
    case .created:
      lifecycle = .starting
      startup = Task {
        try await self.reconcile()
      }
    case .starting: break
    }
    try await startup?.value
    guard lifecycle == .starting || lifecycle == .accepting else {
      throw CoderError.unavailable("Coder is stopping.")
    }
    lifecycle = .accepting
  }

  public func run() async throws {
    do { try await start() } catch {
      try await shutdown()
      throw error
    }
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        try? await gracefulShutdown()
      }
      group.addTask { [failures] in
        for await _ in failures {
          break
        }
      }
      await group.next()
      group.cancelAll()
    }
    try await shutdown()
  }

  /// Closes admission before suspension and joins every registered backend before returning.
  public func shutdown() async throws {
    lifecycle = .stopping
    for (id, task) in tasks {
      do { _ = try store.requestCancellation(id: id, now: Date()) } catch {
        fail(.persistence(error))
      }
      task.cancel()
    }
    let owned = Array(tasks.values)
    _ = await startup?.result
    for task in owned {
      await task.value
    }
    lifecycle = .stopped
    if let failure {
      throw failure
    }
  }

  public func prepare(_ request: CoderRequest) async throws -> CoderPreparedRequest {
    _ = try requireAdmission()
    return try await preparer.prepare(request)
  }

  public func submit(
    _ prepared: CoderPreparedRequest,
    context: ToolExecutionContext
  ) async throws -> CoderJob {
    let origin = try approvedOrigin(context)
    _ = try requireAdmission()
    guard prepared.executionPolicyID == executionPolicyID else {
      throw CoderError.staleApproval
    }
    let current: CoderPreparedRequest
    do { current = try await preparer.prepare(prepared.request) } catch is CancellationError {
      throw CancellationError()
    } catch { throw CoderError.staleApproval }
    try Task.checkCancellation()
    let backend = try requireAdmission()
    guard current == prepared else {
      throw CoderError.staleApproval
    }
    do {
      let admission = try store.admit(
        id: UUID(),
        prepared: prepared,
        origin: origin,
        maxConcurrentJobs: config.maxConcurrentJobs,
        now: Date()
      )
      switch admission {
      case .admitted(let job):
        tasks[job.id] = Task {
          await self.execute(job, backend: backend)
        }
        return job
      case .existing(let job): return job
      case .busy: throw CoderError.busy
      case .workspaceBusy: throw CoderError.workspaceBusy
      case .recoveryRequired: throw CoderError.recoveryRequired
      }
    } catch let error as StoreError {
      fail(.persistence(error))
      throw error
    }
  }

  public func status(id: UUID, context: ToolExecutionContext) async throws -> CoderJob {
    try scopedJob(id: id, context: context)
  }

  public func cancel(id: UUID, context: ToolExecutionContext) async throws -> CoderJob {
    _ = try scopedJob(id: id, context: context)
    do {
      guard let job = try store.requestCancellation(id: id, now: Date()) else {
        throw CoderError.invalidRequest("Coder job was not found.")
      }
      tasks[id]?.cancel()
      return job
    } catch let error as StoreError {
      fail(.persistence(error))
      throw error
    }
  }

  func fail(_ error: CoderServiceFailure) {
    switch (failure, error) {
    case (nil, _), (.cleanup?, .persistence): failure = error
    default: break
    }
    failureSignal.yield(())
  }
}

// MARK: - Admission and Requester Scope

private extension CoderService {
  func requireAdmission() throws -> any CoderBackend {
    guard config.enabled, lifecycle == .accepting, failure == nil, let backend else {
      throw CoderError.unavailable("Coder is not accepting work.")
    }
    return backend
  }

  func approvedOrigin(_ context: ToolExecutionContext) throws -> CoderOrigin {
    guard context.origin == .interactive,
      let requester = context.requesterUserId, requester > 0,
      context.mode == .group || requester == context.chatId,
      let approval = context.approvalId
    else {
      throw CoderError.forbidden
    }
    return CoderOrigin(
      runID: context.runId,
      sessionID: context.sessionId,
      requesterUserID: requester,
      chatID: context.chatId,
      toolCallID: context.toolCallId,
      approvalID: approval
    )
  }

  func scopedJob(id: UUID, context: ToolExecutionContext) throws -> CoderJob {
    guard context.origin == .interactive,
      let requester = context.requesterUserId, requester > 0,
      context.mode == .group || requester == context.chatId
    else {
      throw CoderError.forbidden
    }
    do {
      guard let job = try store.job(id: id) else {
        throw CoderError.invalidRequest("Coder job was not found.")
      }
      guard job.origin.requesterUserID == requester,
        job.origin.chatID == context.chatId,
        context.mode == .direct || job.origin.sessionID == context.sessionId
      else {
        throw CoderError.forbidden
      }
      return job
    } catch let error as StoreError {
      fail(.persistence(error))
      throw error
    }
  }
}
